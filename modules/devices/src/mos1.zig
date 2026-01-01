const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: MOS Level 1 (Shichman-Hodges MOSFET)
//
//   D (external drain) -- RD -- d' (internal drain)
//   S (external source) -- RS -- s' (internal source)
//   G (gate) -- Meyer capacitances --> d', s', B
//   B (bulk) -- junction diodes --> d', s'
//   Channel current flows between d' and s'
// ============================================================================

pub const U = enum(u8) { drain, gate, source, bulk, d_prime, s_prime };
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Polarity ---
    type_: i32 = 1, // 1 = NMOS, -1 = PMOS

    // --- DC Core ---
    vto: f32 = 0, // Zero-bias threshold voltage (V)
    kp: f32 = 2e-5, // Transconductance parameter (A/V^2)
    gamma: f32 = 0, // Bulk threshold (body effect) parameter (V^1/2)
    phi: f32 = 0.6, // Surface inversion potential (V)
    lambda: f32 = 0, // Channel-length modulation (1/V)

    // --- Parasitic Resistance ---
    rd: f32 = 0, // Drain ohmic resistance (Ohm)
    rs: f32 = 0, // Source ohmic resistance (Ohm)
    rsh: f32 = 0, // Diffusion sheet resistance (Ohm/sq)

    // --- Bulk Junction ---
    is: f32 = 1e-14, // Bulk junction saturation current (A)
    js: f32 = 0, // Bulk junction saturation current density (A/m^2)
    pb: f32 = 0.8, // Bulk junction built-in potential (V)

    // --- Junction Capacitance ---
    cbd: f32 = 0, // Zero-bias B-D junction capacitance (F)
    cbs: f32 = 0, // Zero-bias B-S junction capacitance (F)
    cj: f32 = 0, // Bottom junction cap per unit area (F/m^2)
    mj: f32 = 0.5, // Bottom junction grading coefficient
    cjsw: f32 = 0, // Sidewall junction cap per unit perimeter (F/m)
    mjsw: f32 = 0.5, // Sidewall junction grading coefficient
    fc: f32 = 0.5, // Forward-bias junction capacitance fitting parameter

    // --- Overlap Capacitance ---
    cgso: f32 = 0, // Gate-source overlap cap per unit width (F/m)
    cgdo: f32 = 0, // Gate-drain overlap cap per unit width (F/m)
    cgbo: f32 = 0, // Gate-bulk overlap cap per unit length (F/m)

    // --- Oxide / Geometry ---
    tox: f32 = 0, // Gate oxide thickness (m)
    ld: f32 = 0, // Lateral diffusion length (m)
    u0: f32 = 0, // Surface mobility (cm^2/Vs)
    nsub: f32 = 0, // Substrate doping concentration (1/cm^3)
    tpg: i32 = 0, // Gate material type
    nss: f32 = 0, // Surface state density (1/cm^2)

    // --- Temperature ---
    tnom: f32 = 27, // Parameter measurement temperature (degC)

    // --- Noise ---
    kf: f32 = 0, // Flicker noise coefficient
    af: f32 = 1, // Flicker noise exponent
    nlev: i32 = 2, // Noise model level selector
    gdsnoi: f32 = 1, // Channel shot noise coefficient
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 1e-6, // Channel width (m)
    l: f32 = 1e-6, // Channel length (drawn) (m)
    temp: f32 = 300.15, // Device temperature (K)
    dtemp: f32 = 0, // Temperature offset (K)
    m: f32 = 1, // Parallel device multiplier
    ad: f32 = 0, // Drain diffusion area (m^2)
    as_: f32 = 0, // Source diffusion area (m^2)
    pd: f32 = 0, // Drain diffusion perimeter (m)
    ps: f32 = 0, // Source diffusion perimeter (m)
    nrd: f32 = 0, // Number of drain squares (for RSH)
    nrs: f32 = 0, // Number of source squares (for RSH)
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// RD branch: drain -- d_prime
// RS branch: source -- s_prime
// Channel: d_prime -- s_prime (function of gate, bulk voltages)
// Junction BD: bulk -- d_prime
// Junction BS: bulk -- s_prime
// Gate: no DC current, but stamps needed for limiting

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RD branch: drain -- d_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.drain) },
    // RS branch: source -- s_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.source) },
    // Channel + junction self-terms on d_prime and s_prime
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
    // Channel dependence on gate
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.gate) },
    // Channel dependence on bulk (body effect)
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.bulk) },
    // Junction BD: bulk -- d_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.d_prime) },
    // Junction BS: bulk -- s_prime (bulk row/col already present above)
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.s_prime) },
    // Gate row (zero current but needed for completeness)
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Meyer charges: gate -- d_prime, gate -- s_prime, gate -- bulk
// Overlap charges: gate -- drain, gate -- source, gate -- bulk
// Junction depletion charges: bulk -- d_prime, bulk -- s_prime

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Meyer Q_GD: gate -- d_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    // Meyer Q_GS: gate -- s_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
    // Meyer Q_GB: gate -- bulk
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    // Overlap Q_GS_ov: gate -- source (external)
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    // Overlap Q_GD_ov: gate -- drain (external)
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    // Junction Q_BD: bulk -- d_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.bulk) },
    // Junction Q_BS: bulk -- s_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.bulk) },
    // Meyer channel charges couple d_prime and s_prime (mode-swapped vgd/vgs)
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.d_prime) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: drain -- d_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime), .kind = .thermal },
    // Source resistance thermal noise: source -- s_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime), .kind = .thermal },
    // Channel shot noise: d_prime -- s_prime
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime), .kind = .shot },
    // Flicker (1/f) noise: d_prime -- s_prime
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime), .kind = .flicker },
};

// ============================================================================
// x-independent Parameter Preprocessing (pure f64 -- no unknowns involved)
// ============================================================================

const DcParams = struct {
    type_f: f64,
    vt: f64,
    vto: f64,
    gamma: f64,
    phi: f64,
    sqrt_phi: f64,
    lambda: f64,
    beta: f64,
    is_bd: f64,
    is_bs: f64,
    g_rd: f64,
    g_rs: f64,
    m_mult: f64,
};

fn dcParams(model: *const Model, instance: *const Instance) DcParams {
    // --- Cast model parameters to f64 ---
    const vto: f64 = @as(f64, model.vto);
    const kp: f64 = @as(f64, model.kp);
    const gamma: f64 = @as(f64, model.gamma);
    const phi: f64 = @as(f64, model.phi);
    const lambda: f64 = @as(f64, model.lambda);
    const rd: f64 = @as(f64, model.rd);
    const rs: f64 = @as(f64, model.rs);
    const rsh: f64 = @as(f64, model.rsh);
    const is_val: f64 = @as(f64, model.is);
    const js_val: f64 = @as(f64, model.js);
    const ld: f64 = @as(f64, model.ld);

    // --- Cast instance parameters to f64 ---
    const w: f64 = @as(f64, instance.w);
    const l: f64 = @as(f64, instance.l);
    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const m_mult: f64 = @as(f64, instance.m);
    const ad: f64 = @as(f64, instance.ad);
    const as_val: f64 = @as(f64, instance.as_);
    const nrd: f64 = @as(f64, instance.nrd);
    const nrs: f64 = @as(f64, instance.nrs);

    // --- Type factor for NMOS/PMOS ---
    const type_f: f64 = @floatFromInt(model.type_);

    // --- Thermal voltage ---
    const t_dev = temp + dtemp;
    const vt: f64 = 8.617333262145e-5 * t_dev;

    // --- Effective dimensions ---
    const w_eff = @max(w, 1e-9);
    const l_eff = @max(l - 2.0 * ld, 1e-9);

    // --- Effective junction saturation currents ---
    // When JS > 0, use JS * area for each junction; otherwise use IS
    const is_bd: f64 = if (js_val > 0.0) js_val * ad else is_val;
    const is_bs: f64 = if (js_val > 0.0) js_val * as_val else is_val;

    // --- Transconductance factor ---
    const beta = kp * w_eff / l_eff;

    // --- Body effect prefactor ---
    const sqrt_phi = @sqrt(@max(phi, 1e-30));

    // --- Series resistances ---
    // Effective RD = model.rd + rsh * nrd
    // Effective RS = model.rs + rsh * nrs
    // Zero resistance ⇒ the prime node is COLLAPSED onto its port (see
    // collapse() below), so the branch sees v=0 and carries no current.
    // g must be 0, not a 1e12 short: a 1e12 Jacobian entry has ULP 1.2e-4,
    // which absorbs any channel conductance stamped on the same collapsed
    // slot (gds < 1.2e-4 rounds away → Newton loses the linear region).
    const rd_eff = rd + rsh * nrd;
    const rs_eff = rs + rsh * nrs;
    const g_rd: f64 = if (rd_eff != 0.0) m_mult / rd_eff else 0.0;
    const g_rs: f64 = if (rs_eff != 0.0) m_mult / rs_eff else 0.0;

    return .{
        .type_f = type_f,
        .vt = vt,
        // All eval voltages are type-corrected (positive = on); the
        // threshold must be too: PMOS VTO=-0.7 → +0.7 in eval space.
        .vto = type_f * vto,
        .gamma = gamma,
        .phi = phi,
        .sqrt_phi = sqrt_phi,
        .lambda = lambda,
        .beta = beta,
        .is_bd = is_bd,
        .is_bs = is_bs,
        .g_rd = g_rd,
        .g_rs = g_rs,
        .m_mult = m_mult,
    };
}

const QParams = struct {
    type_f: f64,
    m_mult: f64,
    vto: f64,
    gamma: f64,
    phi: f64,
    sqrt_phi: f64,
    c_ox: f64,
    cgso_w: f64,
    cgdo_w: f64,
    cgbo_l: f64,
    pb: f64,
    fc: f64,
    mj: f64,
    mjsw: f64,
    cbd_eff: f64,
    cbs_eff: f64,
    cbdsw: f64,
    cbssw: f64,
};

fn qParams(model: *const Model, instance: *const Instance) QParams {
    // --- Cast model parameters to f64 ---
    const vto: f64 = @as(f64, model.vto);
    const gamma: f64 = @as(f64, model.gamma);
    const phi: f64 = @as(f64, model.phi);
    const ld: f64 = @as(f64, model.ld);
    const tox: f64 = @as(f64, model.tox);
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const cbd_m: f64 = @as(f64, model.cbd);
    const cbs_m: f64 = @as(f64, model.cbs);
    const cj: f64 = @as(f64, model.cj);
    const mj: f64 = @as(f64, model.mj);
    const cjsw: f64 = @as(f64, model.cjsw);
    const mjsw: f64 = @as(f64, model.mjsw);
    const pb: f64 = @as(f64, model.pb);
    const fc: f64 = @as(f64, model.fc);

    // --- Cast instance parameters to f64 ---
    const w: f64 = @as(f64, instance.w);
    const l: f64 = @as(f64, instance.l);
    const m_mult: f64 = @as(f64, instance.m);
    const ad: f64 = @as(f64, instance.ad);
    const as_val: f64 = @as(f64, instance.as_);
    const pd_val: f64 = @as(f64, instance.pd);
    const ps_val: f64 = @as(f64, instance.ps);

    // --- Type factor ---
    const type_f: f64 = @floatFromInt(model.type_);

    // --- Effective dimensions ---
    const w_eff = @max(w, 1e-9);
    const l_eff = @max(l - 2.0 * ld, 1e-9);

    // --- Oxide capacitance ---
    const eps_ox: f64 = 3.9 * 8.854e-12;
    const c_ox_total: f64 = if (tox != 0.0) (eps_ox / tox) * w_eff * l_eff else 0.0;

    // --- Body effect prefactor ---
    const sqrt_phi = @sqrt(@max(phi, 1e-30));

    // --- Effective junction capacitances ---
    // CBD: if model.cbd > 0 use it, else use CJ * AD
    // CBS: if model.cbs > 0 use it, else use CJ * AS
    const cbd_eff: f64 = if (cbd_m > 0.0) cbd_m else cj * ad;
    const cbs_eff: f64 = if (cbs_m > 0.0) cbs_m else cj * as_val;

    // Sidewall capacitances
    const cbdsw: f64 = cjsw * pd_val;
    const cbssw: f64 = cjsw * ps_val;

    return .{
        .type_f = type_f,
        .m_mult = m_mult,
        // Type-corrected, same as dcParams.
        .vto = type_f * vto,
        .gamma = gamma,
        .phi = phi,
        .sqrt_phi = sqrt_phi,
        .c_ox = c_ox_total,
        .cgso_w = cgso * w_eff,
        .cgdo_w = cgdo * w_eff,
        .cgbo_l = cgbo * 2.0 * l_eff,
        .pb = pb,
        .fc = fc,
        .mj = mj,
        .mjsw = mjsw,
        .cbd_eff = cbd_eff,
        .cbs_eff = cbs_eff,
        .cbdsw = cbdsw,
        .cbssw = cbssw,
    };
}

pub const PrepCache = struct { dc: DcParams, q: QParams };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = dcParams(model, instance), .q = qParams(model, instance) };
}

// ============================================================================
// DC Current Function (eval) -- value-form: generic over scalar S
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
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const p = &pc.dc;

    // --- GMIN ---
    const gmin: f64 = 1.0e-12;

    // --- Raw terminal voltages with PMOS sign flip (at internal nodes) ---
    const vgs_raw = x[g].sub(x[sp]).scale(p.type_f);
    const vds_raw = x[dp].sub(x[sp]).scale(p.type_f);
    const vbs_raw = x[b].sub(x[sp]).scale(p.type_f);

    // --- Source-drain reversal (branch on value, like ngspice) ---
    // NOTE: the branchless mode = vds/|vds| form kills the Jacobian at
    // vds = 0 (mode.val() == 0 zeroes the channel conductance stamp).
    const reversed = vds_raw.val() < 0.0;
    const vds_eff = if (reversed) vds_raw.neg() else vds_raw;
    const vgs_eff = if (reversed) vgs_raw.sub(vds_raw) else vgs_raw;
    const vbs_eff = if (reversed) vbs_raw.sub(vds_raw) else vbs_raw;

    // Mode indicator for current direction reconstruction
    const mode_f: f64 = if (reversed) -1.0 else 1.0;

    // --- Body effect and threshold voltage ---
    // Region branch on vbs_eff mirrors the original piecewise selection;
    // each branch computed in S so the Jacobian follows the active branch.
    const sarg = if (vbs_eff.val() <= 0.0)
        vbs_eff.neg().addC(p.phi).maxC(1e-30).sqrt()
    else
        vbs_eff.scale(-1.0 / (2.0 * p.sqrt_phi)).addC(p.sqrt_phi).maxC(0.0);

    const vth = sarg.addC(-p.sqrt_phi).scale(p.gamma).addC(p.vto);

    // --- Gate overdrive ---
    const vgst = vgs_eff.sub(vth);
    const vgst_pos = vgst.maxC(0.0);

    // --- Drain current (Shichman-Hodges) ---
    const vdsat = vgst_pos;
    const vds_ch = vds_eff.min(vdsat);
    const id_val = vgst_pos.sub(vds_ch.scale(0.5)).mul(vds_ch)
        .mul(vds_eff.scale(p.lambda).addC(1.0)).scale(p.beta);

    // Scaled by multiplier
    const id_scaled = id_val.scale(p.m_mult);

    // --- Bulk junction diode currents ---
    // Using raw (non-mode-swapped) voltages relative to bulk
    const vbd = vbs_raw.sub(vds_raw);
    const vbs_junc = vbs_raw;

    const arg_bd = vbd.scale(1.0 / p.vt).minC(80.0);
    const i_bd = arg_bd.exp().addC(-1.0).scale(p.is_bd).add(vbd.scale(gmin));

    const arg_bs = vbs_junc.scale(1.0 / p.vt).minC(80.0);
    const i_bs = arg_bs.exp().addC(-1.0).scale(p.is_bs).add(vbs_junc.scale(gmin));

    // Scaled by multiplier
    const i_bd_s = i_bd.scale(p.m_mult);
    const i_bs_s = i_bs.scale(p.m_mult);

    // --- KCL terminal currents at internal nodes ---
    // i_drain_int = sigma * (mode * I_D_scaled - I_BD_s)
    // i_gate = 0
    // i_source_int = sigma * (-mode * I_D_scaled - I_BS_s)
    // i_bulk = sigma * (I_BD_s + I_BS_s)
    const i_dp_val = id_scaled.scale(mode_f).sub(i_bd_s).scale(p.type_f);
    const i_gate = S.con(0.0);
    const i_sp_val = id_scaled.scale(-mode_f).sub(i_bs_s).scale(p.type_f);
    const i_bulk = i_bd_s.add(i_bs_s).scale(p.type_f);

    // --- Series resistances ---
    // RD: drain -- d_prime
    const i_rd = x[d].sub(x[dp]).scale(p.g_rd);
    // RS: source -- s_prime
    const i_rs = x[s].sub(x[sp]).scale(p.g_rs);

    // --- KCL node stamps ---
    var out: [n_u]S = undefined;
    out[d] = i_rd;
    out[g] = i_gate;
    out[s] = i_rs;
    out[b] = i_bulk;
    out[dp] = i_dp_val.sub(i_rd);
    out[sp] = i_sp_val.sub(i_rs);
    return out;
}

// ============================================================================
// Junction Depletion Charge (shared bottom/sidewall helper)
// ============================================================================
// c0: effective zero-bias capacitance (f64), grading coefficient mjc,
// junction voltage v (S). Reverse-bias uses the graded power law, forward
// bias (v > fc*pb) the quadratic extrapolation -- exactly as the original.

fn junctionCharge(comptime S: type, v: S, c0: f64, pb: f64, mjc: f64, fc: f64) S {
    if (c0 == 0.0) return S.con(0.0);

    const fc_pb = fc * pb;
    const one_minus_m = 1.0 - mjc;
    const one_minus_fc = 1.0 - fc;

    if (v.val() <= fc_pb) {
        // Reverse bias: Q = (C0*PB/(1-M)) * (1 - (1 - V/PB)^(1-M))
        const x_dep = v.scale(-1.0 / pb).addC(1.0).maxC(1e-30);
        return x_dep.log().scale(one_minus_m).exp().neg().addC(1.0).scale(c0 * pb / one_minus_m);
    } else {
        // Forward bias: quadratic extrapolation past FC*PB
        const f1 = (c0 * pb / one_minus_m) * (1.0 - contract.fmath.exp(one_minus_m * contract.fmath.log(one_minus_fc)));
        const f2 = contract.fmath.exp((1.0 + mjc) * contract.fmath.log(one_minus_fc));
        const f3 = 1.0 - fc * (1.0 + mjc);
        const quad = v.mul(v).addC(-fc_pb * fc_pb).scale(mjc / (2.0 * pb));
        return v.addC(-fc_pb).scale(f3).add(quad).scale(c0 / f2).addC(f1);
    }
}

// ============================================================================
// Charge Function (q) -- Meyer Gate Capacitance + Overlap + Junction Depletion
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
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const p = &pc.q;
    const c_ox = p.c_ox;

    // --- Raw terminal voltages with PMOS sign flip (at internal nodes for Meyer) ---
    const vgs_raw = x[g].sub(x[sp]).scale(p.type_f);
    const vds_raw = x[dp].sub(x[sp]).scale(p.type_f);
    const vbs_raw = x[b].sub(x[sp]).scale(p.type_f);

    // --- Source-drain reversal (branchless) for Meyer model ---
    const vds_eff = vds_raw.abs();
    const vds_neg = vds_raw.minC(0.0);
    const vgs_eff = vgs_raw.sub(vds_neg);
    const vbs_eff = vbs_raw.sub(vds_neg);

    // --- Body effect for threshold ---
    const sarg = if (vbs_eff.val() <= 0.0)
        vbs_eff.neg().addC(p.phi).maxC(1e-30).sqrt()
    else
        vbs_eff.scale(-1.0 / (2.0 * p.sqrt_phi)).addC(p.sqrt_phi).maxC(0.0);
    const vth = sarg.addC(-p.sqrt_phi).scale(p.gamma).addC(p.vto);

    // --- Gate overdrive ---
    const vgst = vgs_eff.sub(vth);

    // ========================================================================
    // Meyer Gate Capacitance Model
    // ========================================================================
    const vgst_pos = vgst.maxC(0.0);
    const vdsat_prime = vgst_pos.maxC(1e-30);

    // Select operating region (four-way, branch on voltage as the original):
    // Accumulation: vgst <= -phi
    // Depletion: -phi < vgst <= -phi/2
    // Weak inversion: -phi/2 < vgst <= 0
    // Strong inversion: vgst > 0 (linear vs saturation on vds_eff < vdsat')
    var c_gs_meyer: S = undefined;
    var c_gd_meyer: S = undefined;
    var c_gb_meyer: S = undefined;
    if (vgst.val() <= -p.phi) {
        // Accumulation
        c_gs_meyer = S.con(0.0);
        c_gd_meyer = S.con(0.0);
        c_gb_meyer = S.con(c_ox);
    } else if (vgst.val() <= -p.phi / 2.0) {
        // Depletion
        c_gs_meyer = S.con(0.0);
        c_gd_meyer = S.con(0.0);
        c_gb_meyer = vgst.scale(-c_ox / p.phi);
    } else if (vgst.val() <= 0.0) {
        // Weak inversion
        c_gs_meyer = vgst.scale(c_ox / (1.5 * p.phi)).addC(c_ox / 3.0);
        c_gd_meyer = S.con(0.0);
        c_gb_meyer = vgst.scale(-c_ox / p.phi);
    } else if (vds_eff.val() < vdsat_prime.val()) {
        // Strong inversion, linear region (vds_eff < vdsat')
        const vddif = vdsat_prime.scale(2.0).sub(vds_eff).maxC(1e-30);
        const vddif1 = vdsat_prime.sub(vds_eff);
        const vddif_sq = vddif.mul(vddif);
        c_gs_meyer = vddif1.mul(vddif1).div(vddif_sq).neg().addC(1.0).scale((2.0 / 3.0) * c_ox);
        c_gd_meyer = vdsat_prime.mul(vdsat_prime).div(vddif_sq).neg().addC(1.0).scale((2.0 / 3.0) * c_ox);
        c_gb_meyer = S.con(0.0);
    } else {
        // Strong inversion, saturation region (vds_eff >= vdsat')
        c_gs_meyer = S.con((2.0 / 3.0) * c_ox);
        c_gd_meyer = S.con(0.0);
        c_gb_meyer = S.con(0.0);
    }

    // ========================================================================
    // Meyer Gate Charges (Q = C * V)
    // ========================================================================
    const vgd_eff = vgs_eff.sub(vds_eff);
    const vgb_eff = vgs_eff.sub(vbs_eff);

    const q_gs_meyer = c_gs_meyer.mul(vgs_eff);
    const q_gd_meyer = c_gd_meyer.mul(vgd_eff);
    const q_gb_meyer = c_gb_meyer.mul(vgb_eff);

    // ========================================================================
    // Overlap Charges (using raw un-flipped terminal voltages)
    // ========================================================================
    const q_gs_ov = x[g].sub(x[s]).scale(p.cgso_w);
    const q_gd_ov = x[g].sub(x[d]).scale(p.cgdo_w);
    const q_gb_ov = x[g].sub(x[b]).scale(p.cgbo_l);

    // ========================================================================
    // Junction Depletion Charges
    // ========================================================================
    // Junction voltages (raw, un-mode-swapped)
    const vbs_junc = vbs_raw;
    const vbd_junc = vbs_raw.sub(vds_raw);

    // Bottom + sidewall for each junction
    const q_bd_junc = junctionCharge(S, vbd_junc, p.cbd_eff, p.pb, p.mj, p.fc)
        .add(junctionCharge(S, vbd_junc, p.cbdsw, p.pb, p.mjsw, p.fc));
    const q_bs_junc = junctionCharge(S, vbs_junc, p.cbs_eff, p.pb, p.mj, p.fc)
        .add(junctionCharge(S, vbs_junc, p.cbssw, p.pb, p.mjsw, p.fc));

    // ========================================================================
    // Total Charge per Terminal (scaled by multiplier)
    // ========================================================================
    // Meyer charges are computed in mode-swapped space. Map back to physical
    // terminals (branch on vds sign, as the original mode >= 0 test):
    // In normal mode (vds_raw >= 0): d_prime gets -Q_GD, s_prime gets -Q_GS
    // In reversed mode (vds_raw < 0): d_prime gets -Q_GS, s_prime gets -Q_GD
    const normal_mode = vds_raw.val() >= 0.0;
    const q_meyer_dp = if (normal_mode) q_gd_meyer.neg() else q_gs_meyer.neg();
    const q_meyer_sp = if (normal_mode) q_gs_meyer.neg() else q_gd_meyer.neg();

    // Meyer + junction charges are computed in type-flipped space; the
    // physical charge flips sign for PMOS (ngspice stamps ceqgs/ceqgd/
    // ceqgb/ceqbd/ceqbs with MOS1type). Overlap charges use RAW terminal
    // voltages and need no flip.
    const tm = p.type_f * p.m_mult;
    const q_gate = q_gs_meyer.add(q_gd_meyer).add(q_gb_meyer).scale(tm)
        .add(q_gs_ov.add(q_gd_ov).add(q_gb_ov).scale(p.m_mult));
    const q_drain = q_gd_ov.neg().scale(p.m_mult).sub(q_bd_junc.scale(tm));
    const q_source = q_gs_ov.neg().scale(p.m_mult).sub(q_bs_junc.scale(tm));
    const q_bulk = q_gb_meyer.neg().add(q_bs_junc).add(q_bd_junc).scale(tm).sub(q_gb_ov.scale(p.m_mult));
    const q_dp = q_meyer_dp.scale(tm);
    const q_sp = q_meyer_sp.scale(tm);

    // --- Charge node stamps ---
    var out: [n_u]S = undefined;
    out[d] = q_drain;
    out[g] = q_gate;
    out[s] = q_source;
    out[b] = q_bulk;
    out[dp] = q_dp;
    out[sp] = q_sp;
    return out;
}

// ============================================================================
// Voltage Limiting (DEVfetlim + DEVlimvds + DEVpnjlim)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const is_val: f64 = @as(f64, model.is);
    const type_f: f64 = @floatFromInt(model.type_);
    // fetlim compares type-corrected vgs; the threshold must be too.
    const vto: f64 = type_f * @as(f64, model.vto);

    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);

    const vt: f64 = 8.617333262145e-5 * (temp + dtemp);

    // Critical voltage for pnjlim
    const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * is_val));

    var result = x_new;

    // ========================================================================
    // DEVfetlim -- Gate-Source Voltage Limiting
    // ========================================================================
    {
        const vgs_new = (x_new[g] - x_new[sp]) * type_f;
        const vgs_old = (x_old[g] - x_old[sp]) * type_f;

        const vtox = vto + 3.5;
        const vtsthi = @abs(2.0 * (vgs_old - vto)) + 2.0;
        const vtstlo = vtsthi / 2.0 + 2.0;
        const delta_v = vgs_new - vgs_old;

        var vgs_lim = vgs_new;

        if (vgs_old >= vto) {
            if (vgs_old >= vtox) {
                // Case 1: vgs_old >= vto and vgs_old >= vtox
                if (delta_v <= 0.0) {
                    vgs_lim = @max(vgs_new, vgs_old - vtstlo);
                } else {
                    vgs_lim = @min(vgs_new, vgs_old + vtsthi);
                }
            } else {
                // Case 2: vgs_old >= vto and vgs_old < vtox
                if (delta_v <= 0.0) {
                    vgs_lim = @max(vgs_new, vto - 0.5);
                } else {
                    vgs_lim = @min(vgs_new, vgs_old + vtsthi);
                }
            }
        } else {
            // Case 3: vgs_old < vto
            if (delta_v <= 0.0) {
                vgs_lim = @max(vgs_new, vgs_old - vtstlo);
            } else {
                vgs_lim = @min(vgs_new, vto + 0.5);
            }
        }

        // Apply correction to gate node
        const delta_gs = (vgs_lim - vgs_new) * type_f;
        result[g] += delta_gs;
    }

    // ========================================================================
    // DEVlimvds -- Drain-Source Voltage Limiting
    // ========================================================================
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

        // Apply correction to d_prime node
        const delta_ds = (vds_lim - vds_new) * type_f;
        result[dp] += delta_ds;
    }

    // ========================================================================
    // DEVpnjlim -- Bulk-Source Junction Voltage Limiting
    // ========================================================================
    {
        const vbs_new = (x_new[b] - result[sp]) * type_f;
        const vbs_old = (x_old[b] - x_old[sp]) * type_f;

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
        result[b] += delta_bs;
    }

    // ========================================================================
    // DEVpnjlim -- Bulk-Drain Junction Voltage Limiting
    // ========================================================================
    {
        const vbd_new = (result[b] - result[dp]) * type_f;
        const vbd_old = (x_old[b] - x_old[dp]) * type_f;

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
        // Adjust d_prime (bulk was already adjusted for BS)
        result[dp] -= delta_bd;
    }

    return result;
}

// ============================================================================
// Node Collapse (ngspice MOS1setup: dNodePrime = dNode when RD+RSH·NRD = 0)
// ============================================================================

pub fn collapse(model: *const Model, instance: *const Instance) [n_u]?u8 {
    const rsh: f64 = @as(f64, model.rsh);
    const rd_eff: f64 = @as(f64, model.rd) + rsh * @as(f64, instance.nrd);
    const rs_eff: f64 = @as(f64, model.rs) + rsh * @as(f64, instance.nrs);
    var out: [n_u]?u8 = @splat(null);
    if (rd_eff == 0) out[@intFromEnum(U.d_prime)] = @intFromEnum(U.drain);
    if (rs_eff == 0) out[@intFromEnum(U.s_prime)] = @intFromEnum(U.source);
    return out;
}

// ============================================================================
// Cold-Start Seeding (SPICE MODEINITJCT)
// ============================================================================
// mos1load.c:397-411: at MODEINITJCT vgs = type·vto, vds = 0, vbs = -1.
// Node-write equivalent on a zeroed x: gate = type·vto (s' = 0 ⇒ vgs = vto).
// vds = 0 is already true; vbs = -1 is skipped — bulk is a shared/driven
// rail and a blanket node write would fight other devices on the same well.
// Driven gates snap back in iteration 1's linear solve, after fetlim has
// used vto as its reference — which is the entire point of the seed.

pub fn seed(model: *const Model, _: *const Instance) [n_u]?f64 {
    const vto: f64 = @as(f64, model.vto);
    const type_f: f64 = @floatFromInt(model.type_);
    var out: [n_u]?f64 = @splat(null);
    out[@intFromEnum(U.gate)] = type_f * vto;
    return out;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================
// Gmin stepping: ramp IS from boosted to model value.
// At lambda=0: IS is boosted by gmin; at lambda=1: IS is original.

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is);
    const is_stepped = is_orig + gmin_step * (1.0 - lambda);
    m.is = @floatCast(is_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================
// x order: { drain, gate, source, bulk, d_prime, s_prime }

const testing = std.testing;

test "mos1: NMOS saturation region residual" {
    // vto=1, kp=2e-5 (default), w=l=1e-6 -> beta = kp*w_eff/l_eff = 2e-5
    // vgs=2, vds=2, vbs=0 (gamma=0 -> vth=vto=1)
    // vgst = 1, vdsat = 1, vds_ch = min(2, 1) = 1 (saturation), lambda=0
    // id = beta*(vgst - 0.5*vds_ch)*vds_ch = 2e-5 * 0.5 * 1 = 1e-5
    // vbd = vbs - vds = -2: i_bd = is*(exp(-2/vt)-1) + gmin*(-2)
    //                            ~= -1e-14 - 2e-12 = -2.01e-12
    // vbs = 0: i_bs = 0
    // out[dp] = id - i_bd = 1e-5 + 2.01e-12; out[sp] = -id - i_bs = -1e-5
    // out[bulk] = i_bd + i_bs = -2.01e-12; rd=rs=0 -> i_rd = i_rs = 0
    const model: Model = .{ .vto = 1.0 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 2.0, 2.0, 0.0, 0.0, 2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -2.01e-12), out[3], 1e-18);
    // (tolerance accounts for f32 kp storage)
    try testing.expectApproxEqAbs(@as(f64, 1e-5 + 2.01e-12), out[4], 1e-11);
    try testing.expectApproxEqAbs(@as(f64, -1e-5), out[5], 1e-11);
}

test "mos1: NMOS linear region residual" {
    // vgs=2, vds=0.5 < vdsat=1 -> linear
    // id = 2e-5*(1 - 0.5*0.5)*0.5 = 2e-5*0.75*0.5 = 7.5e-6
    // vbd = -0.5: i_bd = -1e-14 - 0.5e-12 = -5.1e-13; vbs=0: i_bs = 0
    const model: Model = .{ .vto = 1.0 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.5, 2.0, 0.0, 0.0, 0.5, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -5.1e-13), out[3], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 7.5e-6 + 5.1e-13), out[4], 1e-11);
    try testing.expectApproxEqAbs(@as(f64, -7.5e-6), out[5], 1e-11);
}

test "mos1: NMOS reversed (vds < 0) mode residual" {
    // drain at 0V, source at 2V: vgs_raw = 0, vds_raw = -2, vbs_raw = -2
    // mode swap: vds_eff = 2, vgs_eff = 0-(-2) = 2, vbs_eff = 0 -> vgst = 1
    // id = 1e-5, mode = -1: current flows s'->d'
    // vbd = vbs_raw - vds_raw = 0: i_bd = 0
    // vbs = -2: i_bs = -1e-14 - 2e-12 = -2.01e-12
    // out[dp] = mode*id - i_bd = -1e-5
    // out[sp] = -mode*id - i_bs = 1e-5 + 2.01e-12
    const model: Model = .{ .vto = 1.0 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.0, 2.0, 2.0, 0.0, 0.0, 2.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -2.01e-12), out[3], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, -1e-5), out[4], 1e-11);
    try testing.expectApproxEqAbs(@as(f64, 1e-5 + 2.01e-12), out[5], 1e-11);
}

test "mos1: PMOS saturation region residual" {
    // type=-1 flips all terminal voltages: with x[g]=x[dp]=-2, x[sp]=0,
    // vgs_raw = 2, vds_raw = 2, vbs_raw = 0 -> same flipped-space physics as
    // the NMOS saturation test (vgst = 1, id = 1e-5, i_bd = -2.01e-12), then
    // terminal currents flip sign via type_f. A PMOS enhancement device has
    // NEGATIVE model VTO (flipped-space threshold = type*vto = +1).
    const model: Model = .{ .type_ = -1, .vto = -1.0 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ -2.0, -2.0, 0.0, 0.0, -2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 2.01e-12), out[3], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, -(1e-5 + 2.01e-12)), out[4], 1e-11);
    try testing.expectApproxEqAbs(@as(f64, 1e-5), out[5], 1e-11);
}

test "mos1: Meyer gate charge in saturation" {
    // tox=1e-7, w=l=1e-6:
    // c_ox = (3.9*8.854e-12/1e-7)*1e-6*1e-6 = 3.45306e-16
    // vgs=2, vds=2, vto=1 -> vgst = 1 > 0, vds_eff=2 >= vdsat'=1: saturation
    // c_gs = (2/3)c_ox, c_gd = 0, c_gb = 0
    // q_gs = (2/3)*3.45306e-16*2 = 4.60408e-16, q_gd = q_gb = 0
    // q_gate = 4.60408e-16, q_sp = -q_gs = -4.60408e-16, q_dp = -q_gd = 0
    // (no overlap caps, no junction caps in this model card)
    const model: Model = .{ .vto = 1.0, .tox = 1e-7 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 2.0, 2.0, 0.0, 0.0, 2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-21);
    try testing.expectApproxEqAbs(@as(f64, 4.60408e-16), out[1], 1e-21);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-21);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-21);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[4], 1e-21);
    try testing.expectApproxEqAbs(@as(f64, -4.60408e-16), out[5], 1e-21);
}

test "mos1: reverse-biased BS junction depletion charge" {
    // cbs=1e-12, pb=0.8, mj=0.5, fc=0.5 -> fc*pb = 0.4
    // x[b] = -1 -> vbs_junc = -1 <= 0.4: reverse-bias branch
    // x_dep = 1 - (-1)/0.8 = 2.25
    // q_bs = (1e-12*0.8/0.5)*(1 - 2.25^0.5) = 1.6e-12*(1 - 1.5) = -8e-13
    // vbd_junc = -1 but cbd_eff = 0 -> q_bd = 0; tox=0 -> no Meyer charge
    // q_source = -q_bs = 8e-13; q_bulk = q_bs = -8e-13
    const model: Model = .{ .cbs = 1e-12 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0.0, 0.0, 0.0, -1.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-21);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-21);
    try testing.expectApproxEqAbs(@as(f64, 8e-13), out[2], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, -8e-13), out[3], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[4], 1e-21);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[5], 1e-21);
}
