use incspice_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::device::eval::{DeviceEval, DeviceModel};

const GDS_MIN: f64 = 1e-12;
const VT_THERMAL: f64 = 0.02585;

/// MOSFET Level 1 (Shichman-Hodges) model: 4-terminal device.
///
/// Pin 0 = drain, Pin 1 = gate, Pin 2 = source, Pin 3 = bulk.
/// Parameters: `kp` (transconductance, default 2e-5),
///             `vth` (threshold voltage, default 0.7),
///             `lambda` (channel-length modulation, default 0.0),
///             `w` (width, default 1e-6), `l` (length, default 1e-6).
///
/// This implements the NMOS model. PMOS flips voltage polarities.
#[derive(Debug, Clone, Copy)]
pub struct MosfetLevel1;

/// Compute depletion capacitance for a single component (bottom or sidewall).
/// Uses sqrt() fast path when mj is close to 0.5 (ngspice mos1load.c optimization).
fn depletion_cap_single(cj: f64, v: f64, vj: f64, mj: f64) -> f64 {
    if cj == 0.0 {
        return 0.0;
    }
    let ratio = 1.0 - v / vj;
    if (mj - 0.5).abs() < 1e-6 {
        cj / ratio.sqrt()
    } else {
        cj * ratio.powf(-mj)
    }
}

/// Compute depletion charge for a single component (bottom or sidewall).
fn depletion_charge_single(cj: f64, v: f64, vj: f64, mj: f64) -> f64 {
    if cj == 0.0 {
        return 0.0;
    }
    if (mj - 1.0).abs() < 1e-9 {
        -cj * vj * (1.0 - v / vj).ln()
    } else {
        cj * vj / (1.0 - mj) * (1.0 - (1.0 - v / vj).powf(1.0 - mj))
    }
}

/// Combined bottom + sidewall junction capacitance and charge.
///
/// Two-region model matching ngspice mos1load.c:567-674:
/// - Depletion region (v <= fc*vj): C = cj * (1 - v/vj)^(-mj)
/// - Forward bias (v > fc*vj): polynomial continuation via f2/f3/f4 coefficients
///
/// Returns (total_capacitance, total_charge).
fn diode_junction_cap_with_sidewall(
    cj_bottom: f64,
    cj_sidewall: f64,
    v: f64,
    vj: f64,
    mj: f64,
    mjsw: f64,
    fc: f64,
) -> (f64, f64) {
    if cj_bottom == 0.0 && cj_sidewall == 0.0 {
        return (0.0, 0.0);
    }

    let v_limit = fc * vj;

    if v <= v_limit {
        // Depletion region
        let cap_bot = depletion_cap_single(cj_bottom, v, vj, mj);
        let cap_sw = depletion_cap_single(cj_sidewall, v, vj, mjsw);
        let q_bot = depletion_charge_single(cj_bottom, v, vj, mj);
        let q_sw = depletion_charge_single(cj_sidewall, v, vj, mjsw);
        (cap_bot + cap_sw, q_bot + q_sw)
    } else {
        // Forward bias -- polynomial continuation (ngspice f2/f3/f4 coefficients)

        // Bottom component
        let f1 = (1.0 - fc).powf(1.0 + mj);
        let f2 = cj_bottom / f1 * (1.0 - fc * (1.0 + mj));
        let f3 = cj_bottom * mj / (f1 * vj);
        let cap_bot = f2 + f3 * v;
        let f4 = if (mj - 1.0).abs() < 1e-9 {
            -cj_bottom * vj * (1.0 - fc).ln()
        } else {
            cj_bottom * vj / (1.0 - mj) * (1.0 - (1.0 - fc).powf(1.0 - mj))
        };
        let q_bot = f4 + v * (f2 + v * f3 / 2.0);

        // Sidewall component
        let f1sw = (1.0 - fc).powf(1.0 + mjsw);
        let f2sw = cj_sidewall / f1sw * (1.0 - fc * (1.0 + mjsw));
        let f3sw = cj_sidewall * mjsw / (f1sw * vj);
        let cap_sw = f2sw + f3sw * v;
        let f4sw = if (mjsw - 1.0).abs() < 1e-9 {
            -cj_sidewall * vj * (1.0 - fc).ln()
        } else {
            cj_sidewall * vj / (1.0 - mjsw) * (1.0 - (1.0 - fc).powf(1.0 - mjsw))
        };
        let q_sw = f4sw + v * (f2sw + v * f3sw / 2.0);

        (cap_bot + cap_sw, q_bot + q_sw)
    }
}

fn diode_iv(is: f64, nvt: f64, vj: f64) -> (f64, f64) {
    if is <= 0.0 {
        return (0.0, 0.0);
    }

    let vcrit = nvt * (nvt / (std::f64::consts::SQRT_2 * is.max(1e-300))).ln();
    let vlimit = vcrit + 10.0 * nvt;

    if vj <= vlimit {
        let exp_val = (vj / nvt).exp();
        (is * (exp_val - 1.0), is * exp_val / nvt)
    } else {
        let exp_lim = (vlimit / nvt).exp();
        let gd = is * exp_lim / nvt;
        let id = is * (exp_lim - 1.0) + gd * (vj - vlimit);
        (id, gd)
    }
}

fn mos_body_junctions(
    voltages: &[f64],
    params: &ParamMap,

    is_pmos: bool,
) -> (
    [f64; 4],
    [f64; 4],
    SmallVec<[(u8, u8, f64); 16]>,
    SmallVec<[(u8, u8, f64); 16]>,
) {
    // Bottom junction capacitances: CBD/CBS directly, or CJ * AD/AS
    let cj_per_area = params.get_or("cj", 0.0);
    let ad = params.get_or("ad", 0.0);
    let as_ = params.get_or("as", 0.0);
    let cdb_bottom = if let Some(cbd) = params.get("cbd") {
        cbd
    } else {
        cj_per_area * ad
    };
    let csb_bottom = if let Some(cbs) = params.get("cbs") {
        cbs
    } else {
        cj_per_area * as_
    };

    // Sidewall junction capacitances: CBDSW/CBSSW directly, or CJSW * PD/PS
    let cjsw = params.get_or("cjsw", 0.0);
    let pd = params.get_or("pd", 0.0);
    let ps = params.get_or("ps", 0.0);
    let cdb_sw = if let Some(cbdsw) = params.get("cbdsw") {
        cbdsw
    } else {
        cjsw * pd
    };
    let csb_sw = if let Some(cbssw) = params.get("cbssw") {
        cbssw
    } else {
        cjsw * ps
    };

    let is = params.get_or("is", 0.0)
        * params.get_or("area", 1.0).max(1e-30)
        * params.get_or("m", 1.0).max(1e-30);
    let nvt = params.get_or("n", 1.0).max(1e-6) * VT_THERMAL;
    let pb = params.get_or("pb", 0.8).max(0.01);
    let mj = params.get_or("mj", 0.5);
    let mjsw = params.get_or("mjsw", 0.33);
    let fc = params.get_or("fc", 0.5).clamp(0.0, 0.999);
    let tt = params.get_or("tt", 0.0).max(0.0);
    let orient = if is_pmos { -1.0 } else { 1.0 };

    let mut g = [0.0; 4];
    let mut q = [0.0; 4];
    let mut g_jac = SmallVec::<[(u8, u8, f64); 16]>::new();
    let mut c = SmallVec::<[(u8, u8, f64); 16]>::new();

    for (pin, cj_bot, cj_sw) in [(0u8, cdb_bottom, cdb_sw), (2u8, csb_bottom, csb_sw)] {
        if is == 0.0 && cj_bot == 0.0 && cj_sw == 0.0 {
            continue;
        }

        let vj = orient * (voltages[3] - voltages[pin as usize]);
        let (ij, gj) = diode_iv(is, nvt, vj);
        let (c_dep, q_dep) = diode_junction_cap_with_sidewall(cj_bot, cj_sw, vj, pb, mj, mjsw, fc);
        let q_tt = tt * ij;
        let c_tt = tt * gj;
        let q_total = q_dep + q_tt;
        let c_total = c_dep + c_tt;

        g[pin as usize] -= orient * ij;
        g[3] += orient * ij;

        if gj != 0.0 {
            g_jac.extend([(pin, pin, gj), (pin, 3, -gj), (3, pin, -gj), (3, 3, gj)]);
        }

        q[pin as usize] -= orient * q_total;
        q[3] += orient * q_total;

        if c_total != 0.0 {
            c.extend([
                (pin, pin, c_total),
                (pin, 3, -c_total),
                (3, pin, -c_total),
                (3, 3, c_total),
            ]);
        }
    }

    (g, q, g_jac, c)
}

fn mos_gate_caps(
    voltages: &[f64],
    params: &ParamMap,
    w: f64,
    l: f64,
    vov: f64,
    vds: f64,
    _vdsat: f64,
    reversed: bool,
) -> ([f64; 4], SmallVec<[(u8, u8, f64); 16]>) {
    // always compute Cox; ngspice defaults tox=100nm
    let cgso_ov = params.get_or("cgso", 0.0) * w;
    let cgdo_ov = params.get_or("cgdo", 0.0) * w;
    let ld = params.get_or("ld", 0.0);
    let leff = (l - 2.0 * ld).max(1e-9);
    let cgbo_ov = params.get_or("cgbo", 0.0) * leff;

    let orient = if params.get_or("pmos", 0.0) != 0.0 { -1.0 } else { 1.0 };

    const EPSOX_CAP: f64 = 3.453e-11;
    let tox = params.get_or("tox", 1e-7).max(1e-12);
    let cox = EPSOX_CAP / tox * w * leff;

    // Ward-Dutton charge-based model: continuous charges at region boundaries.
    let vgd_phys = voltages[1] - voltages[0];
    let vgs_phys = voltages[1] - voltages[2];
    let vgb_phys = voltages[1] - voltages[3];

    let (q_gs_i, q_gd_i, q_gb_i, c_gs_i, c_gd_i, c_gb_i) = if vov <= 0.0 {
        // Cutoff: all gate charge on bulk
        (0.0, 0.0, cox * vgb_phys * orient, 0.0, 0.0, cox)
    } else {
        // Ward-Dutton continuous charge model.
        // In saturation, clamp Vds to Vdsat=Vov so charges are continuous
        // by construction at the triode/saturation boundary.
        let vds_c = vds.abs().min(vov).max(0.0);
        let a = vov - vds_c / 2.0; // always > 0 since vds_c <= vov
        let a2 = a * a;

        // Total inversion charge (numerically stable form):
        //   Qi = -Cox * (Vov³ - (Vov-Vds)³) / (3*D)
        //      = -Cox * (3*Vov² - 3*Vov*Vds + Vds²) / (3*(Vov - Vds/2))
        // (unused directly; we compute Qs and Qd)

        // Drain share of inversion charge (Ward-Dutton 40/60 partition):
        //   Qd = -Cox * Vds² / D² * P
        //      = -Cox * P / (Vov - Vds/2)²
        //   where P = Vov³/2 - 5*Vov²*Vds/6 + Vov*Vds²/2 - Vds³/10
        //   At Vds=Vov: Qd = -2/5 * Cox * Vov (40% of Qi)
        //   At Vds=0:   Qd = -Cox * Vov / 2    (50% of Qi)
        let p_poly = vov * vov * vov / 2.0
            - 5.0 * vov * vov * vds_c / 6.0
            + vov * vds_c * vds_c / 2.0
            - vds_c * vds_c * vds_c / 10.0;
        let neg_qd = cox * p_poly / a2; // = -Qd (positive for NMOS)

        // Source share: Qs = Qi - Qd
        //   -Qs = Cox*(3*Vov² - 3*Vov*Vds + Vds²)/(3*(Vov-Vds/2)) - (-Qd)
        //       = Cox*(3*Vov² - 3*Vov*Vds + Vds²)/(3*a) - neg_qd ... but simpler:
        // Direct formula for -Qs (numerically stable):
        //   -Qs = Cox * (6*Vov³ - 15*Vov²*Vds + 12*Vov*Vds² - 3*Vds³
        //          - (15*Vov³ - 25*Vov²*Vds + 15*Vov*Vds² - 3*Vds³))
        //        / (30 * a²)
        //   ... too complex; just use Qi - Qd with stable Qi formula.
        let qi_neg = cox * (3.0 * vov * vov - 3.0 * vov * vds_c + vds_c * vds_c)
            / (3.0 * a); // = -Qi (positive)
        let neg_qs = qi_neg - neg_qd; // = -Qs (positive)

        let q_gs = orient * neg_qs;
        let q_gd = orient * neg_qd;

        // Capacitances for Newton Jacobian (Meyer-style, continuous).
        // These approximate dQ/dV for convergence; the charges above
        // determine transient accuracy.
        let vds_ratio_sq = (vds_c * vds_c) / (4.0 * a2); // (Vds/(2*Vov-Vds))²
        let c_gs = cox * 0.5 * (1.0 + vds_ratio_sq);
        let c_gd = cox * 0.5 * (1.0 - vds_ratio_sq);

        (q_gs, q_gd, 0.0, c_gs, c_gd, 0.0)
    };

    // Total capacitances (intrinsic + overlap)
    let (c_gd, c_gs, c_gb) = if reversed {
        (c_gs_i + cgdo_ov, c_gd_i + cgso_ov, c_gb_i + cgbo_ov)
    } else {
        (c_gd_i + cgdo_ov, c_gs_i + cgso_ov, c_gb_i + cgbo_ov)
    };

    let has_caps = c_gd != 0.0 || c_gs != 0.0 || c_gb != 0.0;

    let mut c = SmallVec::<[(u8, u8, f64); 16]>::new();
    if has_caps {
        c.extend([
            (0, 0, c_gd),
            (0, 1, -c_gd),
            (1, 0, -c_gd),
            (1, 1, c_gd + c_gs + c_gb),
            (1, 2, -c_gs),
            (1, 3, -c_gb),
            (2, 1, -c_gs),
            (2, 2, c_gs),
            (3, 1, -c_gb),
            (3, 3, c_gb),
        ]);
    }

    // Charges: intrinsic (Ward-Dutton) + overlap
    let (q_gd_i_r, q_gs_i_r) = if reversed { (q_gs_i, q_gd_i) } else { (q_gd_i, q_gs_i) };
    let q_drain  = -q_gd_i_r - cgdo_ov * vgd_phys;
    let q_gate   = q_gd_i_r + q_gs_i_r + q_gb_i
                   + cgdo_ov * vgd_phys + cgso_ov * vgs_phys + cgbo_ov * vgb_phys;
    let q_source = -q_gs_i_r - cgso_ov * vgs_phys;
    let q_bulk   = -q_gb_i - cgbo_ov * vgb_phys;

    (
        [q_drain, q_gate, q_source, q_bulk],
        c,
    )
}

impl DeviceModel for MosfetLevel1 {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let kp = params.get("kp").unwrap_or(2e-5);
        let vto = params
            .get("vto")
            .or_else(|| params.get("vth0"))
            .or_else(|| params.get("vth"))
            .unwrap_or(0.7);
        let lambda = params.get("lambda").unwrap_or(0.0);
        let w = params.get_or("w", 1e-6);
        let l = params.get_or("l", 1e-6);
        let ld = params.get_or("ld", 0.0);
        let leff = (l - 2.0 * ld).max(1e-9);
        let gamma = params.get_or("gamma", 0.0);
        let phi = params.get_or("phi", 0.6).max(0.1);
        let beta = kp * w / leff;

        let is_pmos = params.get_or("pmos", 0.0) != 0.0;
        let sign = if is_pmos { -1.0 } else { 1.0 };

        let vgs_raw = sign * (voltages[1] - voltages[2]);
        let vds_raw = sign * (voltages[0] - voltages[2]);
        let vbs_raw = sign * (voltages[3] - voltages[2]);

        // Source-drain swap: when Vds < 0 the physical drain is at a lower
        // potential than the source.  Standard SPICE (ngspice DEVmosfet1load)
        // swaps drain and source internally so that the Shichman-Hodges
        // equations always see Vds >= 0.  The effective gate voltage becomes
        // Vgd (gate-to-drain) and Vds is negated.  After evaluation the
        // current is negated and the Jacobian columns for D/S are swapped.
        let (vgs, vds, vbs, reversed) = if vds_raw >= 0.0 {
            (vgs_raw, vds_raw, vbs_raw, false)
        } else {
            // Swap D↔S: vgs' = vgd, vds' = -vds, vbs' = vbd
            (vgs_raw - vds_raw, -vds_raw, vbs_raw - vds_raw, true)
        };

        // Body effect: Vth = vto + gamma*(sqrt(phi + Vsb) - sqrt(phi))
        // vsb = Vs - Vb = -Vbs (source-bulk voltage, positive when body reverse-biased)
        let vsb = -vbs;
        let sqrt_phi_vsb = (phi + vsb.max(-phi + 1e-12)).sqrt();
        let sqrt_phi = phi.sqrt();
        let vth_base = if is_pmos { vto.abs() } else { vto };
        let vth_eff = if is_pmos {
            vth_base + gamma * (sqrt_phi - sqrt_phi_vsb)
        } else {
            vth_base + gamma * (sqrt_phi_vsb - sqrt_phi)
        };
        let vov = vgs - vth_eff;

        let (id, gm, gds) = if vov <= 0.0 {
            // Cutoff — only GDS_MIN leakage.
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else if vds < vov {
            // Linear (triode) region.
            let id = beta * (vov * vds - 0.5 * vds * vds) * (1.0 + lambda * vds) + GDS_MIN * vds;
            let gm = beta * vds;
            let gds = beta * (vov - vds)
                + lambda * beta * vds * (vov - 0.5 * vds)
                + GDS_MIN;
            (id, gm, gds)
        } else {
            // Saturation region.
            let id = 0.5 * beta * vov * vov * (1.0 + lambda * vds) + GDS_MIN * vds;
            let gm = beta * vov;
            let gds = 0.5 * beta * vov * vov * lambda + GDS_MIN;
            (id, gm, gds)
        };

        // Body-effect transconductance: gmbs = gm * gamma / (2 * sqrt(phi + Vsb))
        let gmbs = if sqrt_phi_vsb > 1e-6 {
            gm * gamma / (2.0 * sqrt_phi_vsb)
        } else {
            0.0
        };

        // When reversed, physical current flows source→drain (pin 2 → pin 0),
        // so the current seen at pin 0 is −id and at pin 2 is +id.
        // The Jacobian columns for D(pin 0) and S(pin 2) swap because the
        // internal variables were evaluated with swapped terminals.
        let id_signed = if reversed { -sign * id } else { sign * id };

        // Jacobian: in the normal case gm = dId/dVgs, gds = dId/dVds, and
        // sign cancels in the chain rule so stamps use unsigned gm, gds.
        //
        // In the reversed case the derivatives are w.r.t. the swapped
        // voltages.  Transforming back to physical pins (see derivation in
        // BSIM4 eval.rs):
        //   dI_D/dV_D = gm + gds,   dI_D/dV_G = -gm,   dI_D/dV_S = -gds
        //   dI_S/dV_D = -(gm+gds),  dI_S/dV_G = +gm,   dI_S/dV_S = +gds
        let (g_dd, g_dg, g_ds, g_db, g_sd, g_sg, g_ss, g_sb) = if reversed {
            (
                gm + gds + gmbs,
                -gm,
                -gds,
                -gmbs,
                -(gm + gds + gmbs),
                gm,
                gds,
                gmbs,
            )
        } else {
            (
                gds,
                gm,
                -(gm + gds + gmbs),
                gmbs,
                -gds,
                -gm,
                gm + gds + gmbs,
                -gmbs,
            )
        };

        let (g_junc, q_junc, g_jac_junc, c_junc) = mos_body_junctions(voltages, params, is_pmos);
        let (q_gate, c_gate) =
            mos_gate_caps(voltages, params, w, l, vov, vds, vov.max(0.0), reversed);
        let mut c = c_gate;
        c.extend(c_junc);
        let mut g_total = smallvec![id_signed, 0.0, -id_signed, 0.0];
        let mut q_total = smallvec![q_gate[0], q_gate[1], q_gate[2], q_gate[3]];
        for i in 0..4 {
            g_total[i] += g_junc[i];
            q_total[i] += q_junc[i];
        }

        let mut g_entries = smallvec![
            (0, 0, g_dd),
            (0, 1, g_dg),
            (0, 2, g_ds),
            (0, 3, g_db),
            (2, 0, g_sd),
            (2, 1, g_sg),
            (2, 2, g_ss),
            (2, 3, g_sb),
            (3u8, 3u8, GDS_MIN),
        ];
        g_entries.extend(g_jac_junc);

        DeviceEval {
            g: g_total,
            q: q_total,
            G: g_entries,
            C: c,
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::MosfetN
    }
}

/// MOSFET Level 2 (Grove-Frohman bulk-charge model): 4-terminal device.
///
/// Pin 0 = drain, Pin 1 = gate, Pin 2 = source, Pin 3 = bulk.
/// Adds body effect via `gamma` (bulk threshold parameter) and `phi` (surface potential).
/// Parameters: `kp`, `vto`, `lambda`, `w`, `l`, `gamma`, `phi`.
#[derive(Debug, Clone, Copy)]
pub struct MosfetLevel2;

impl DeviceModel for MosfetLevel2 {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let vto = params
            .get("vto")
            .or_else(|| params.get("vth0"))
            .unwrap_or(0.7);
        let lambda = params.get_or("lambda", 0.0);
        let w = params.get_or("w", 1e-6);
        let l = params.get_or("l", 1e-6);
        let ld = params.get_or("ld", 0.0);
        let leff = (l - 2.0 * ld).max(1e-9);

        // Derive kp from uo and tox if not explicitly given.
        // uo is surface mobility in cm²/V·s; eps_ox in F/m; tox in m.
        // kp = uo * eps_ox / tox  (with uo converted: cm²/V·s * 1e-4 = m²/V·s)
        const EPSSI: f64 = 1.045e-10; // eps_si = 11.7 * 8.854e-12
        const Q_E: f64 = 1.602e-19;
        const EPSOX: f64 = 3.453e-11;

        let kp = if let Some(kp_val) = params.get("kp") {
            kp_val
        } else if let (Some(uo), Some(tox)) = (params.get("uo"), params.get("tox")) {
            // uo in cm²/V·s → multiply by 1e-4 to get m²/V·s
            uo * 1e-4 * EPSOX / tox
        } else {
            2e-5
        };
        let gamma = if let Some(g) = params.get("gamma") {
            g
        } else if let (Some(nsub), Some(tox)) = (params.get("nsub"), params.get("tox")) {
            let cox_per_area = EPSOX / tox;
            (2.0 * EPSSI * Q_E * nsub).sqrt() / cox_per_area
        } else {
            0.0
        };

        // Derive phi from nsub if not explicitly given.
        const NI: f64 = 1.45e10; // intrinsic carrier concentration Si @ 300K
        const VT_DERIV: f64 = 0.02585; // thermal voltage @ 300K
        let phi = if let Some(p) = params.get("phi") {
            p.max(0.1)
        } else if let Some(nsub) = params.get("nsub") {
            (2.0 * VT_DERIV * (nsub / NI).ln()).max(0.1)
        } else {
            0.6
        };

        let beta = kp * w / leff;

        let is_pmos = params.get_or("pmos", 0.0) != 0.0;
        let sign = if is_pmos { -1.0 } else { 1.0 };

        let vgs_raw = sign * (voltages[1] - voltages[2]);
        let vds_raw = sign * (voltages[0] - voltages[2]);
        let vbs_raw = sign * (voltages[3] - voltages[2]);

        // Source-drain swap when Vds < 0 (see MosfetLevel1 for full explanation).
        let (vgs, vds, vbs, reversed) = if vds_raw >= 0.0 {
            (vgs_raw, vds_raw, vbs_raw, false)
        } else {
            // Swap D↔S: vgs' = vgd, vds' = -vds, vbs' = vbd
            (vgs_raw - vds_raw, -vds_raw, vbs_raw - vds_raw, true)
        };

        // Body effect: Vth = vto + gamma*(sqrt(phi + Vsb) - sqrt(phi))
        let vsb = -vbs;
        let sqrt_phi_vsb = (phi + vsb.max(-phi + 1e-12)).sqrt();
        let sqrt_phi = phi.sqrt();
        let vth = if is_pmos {
            vto.abs() + gamma * (sqrt_phi - sqrt_phi_vsb)
        } else {
            vto + gamma * (sqrt_phi_vsb - sqrt_phi)
        };

        let vov = vgs - vth;
        let (mut id, mut gm, mut gds) = if vov <= 0.0 {
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else if vds < vov {
            let id = beta * (vov * vds - 0.5 * vds * vds) * (1.0 + lambda * vds) + GDS_MIN * vds;
            let gm = beta * vds;
            let gds = beta * (vov - vds)
                + lambda * beta * vds * (vov - 0.5 * vds)
                + GDS_MIN;
            (id, gm, gds)
        } else {
            let id = 0.5 * beta * vov * vov * (1.0 + lambda * vds) + GDS_MIN * vds;
            let gm = beta * vov;
            let gds = 0.5 * beta * vov * vov * lambda + GDS_MIN;
            (id, gm, gds)
        };

        // Velocity saturation (ucrit/uexp)
        let ucrit = params.get_or("ucrit", 0.0);
        let uexp = params.get_or("uexp", 0.0);
        if ucrit > 0.0 && uexp > 0.0 && vov > 0.0 {
            let e_field = vds.abs() / leff;
            let mu_factor = 1.0 / (1.0 + (e_field / ucrit).powf(uexp));
            id *= mu_factor;
            gm *= mu_factor;
            gds *= mu_factor;
        }

        // Body-effect transconductance: gmb = gm * gamma / (2 * sqrt(phi + Vsb))
        let gmb = if sqrt_phi_vsb > 1e-6 {
            gm * gamma / (2.0 * sqrt_phi_vsb)
        } else {
            0.0
        };

        let id_signed = if reversed { -sign * id } else { sign * id };

        // Jacobian: when reversed, D/S columns swap (see MosfetLevel1).
        let (g_dd, g_dg, g_ds, g_db, g_sd, g_sg, g_ss, g_sb) = if reversed {
            (
                gm + gds + gmb,
                -gm,
                -gds,
                -gmb,
                -(gm + gds + gmb),
                gm,
                gds,
                gmb,
            )
        } else {
            (
                gds,
                gm,
                -(gm + gds + gmb),
                gmb,
                -gds,
                -gm,
                gm + gds + gmb,
                -gmb,
            )
        };

        let (g_junc, q_junc, g_jac_junc, c_junc) = mos_body_junctions(voltages, params, is_pmos);
        let (q_gate, c_gate) =
            mos_gate_caps(voltages, params, w, l, vov, vds, vov.max(0.0), reversed);
        let mut q_total = smallvec![q_gate[0], q_gate[1], q_gate[2], q_gate[3]];
        let mut g_total = smallvec![id_signed, 0.0, -id_signed, 0.0];
        for i in 0..4 {
            g_total[i] += g_junc[i];
            q_total[i] += q_junc[i];
        }

        let mut g_entries = smallvec![
            (0, 0, g_dd),
            (0, 1, g_dg),
            (0, 2, g_ds),
            (0, 3, g_db),
            (2, 0, g_sd),
            (2, 1, g_sg),
            (2, 2, g_ss),
            (2, 3, g_sb),
            (3u8, 3u8, GDS_MIN),
        ];
        g_entries.extend(g_jac_junc);

        let mut c_total = c_gate;
        c_total.extend(c_junc);

        DeviceEval {
            g: g_total,
            q: q_total,
            G: g_entries,
            C: c_total,
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::MosfetN2
    }
}

/// MOSFET Level 3 (empirical model): 4-terminal device.
///
/// Pin 0 = drain, Pin 1 = gate, Pin 2 = source, Pin 3 = bulk.
/// Adds DIBL (`eta`), mobility degradation (`theta`), narrow-width (`delta`),
/// and saturation field factor (`kappa`) on top of the Level 2 body effect.
#[derive(Debug, Clone, Copy)]
pub struct MosfetLevel3;

impl DeviceModel for MosfetLevel3 {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let kp = params.get_or("kp", 2e-5);
        let vto = params
            .get("vto")
            .or_else(|| params.get("vth0"))
            .unwrap_or(0.7);
        let lambda = params.get_or("lambda", 0.0);
        let w = params.get_or("w", 1e-6);
        let l = params.get_or("l", 1e-6);
        let ld = params.get_or("ld", 0.0);
        let leff = (l - 2.0 * ld).max(1e-9);
        let gamma = params.get_or("gamma", 0.0);
        let phi = params.get_or("phi", 0.6).max(0.1);
        let eta = params.get_or("eta", 0.0); // DIBL coefficient
        let theta = params.get_or("theta", 0.0); // mobility degradation
        let delta = params.get_or("delta", 0.0); // narrow-width effect
        let kappa = params.get_or("kappa", 0.2); // saturation field factor
        let beta0 = kp * w / leff;

        let is_pmos = params.get_or("pmos", 0.0) != 0.0;
        let sign = if is_pmos { -1.0 } else { 1.0 };

        let vgs_raw = sign * (voltages[1] - voltages[2]);
        let vds_raw = sign * (voltages[0] - voltages[2]);
        let vbs_raw = sign * (voltages[3] - voltages[2]);

        // Source-drain swap when Vds < 0 (see MosfetLevel1 for full explanation).
        let (vgs, vds, vbs, reversed) = if vds_raw >= 0.0 {
            (vgs_raw, vds_raw, vbs_raw, false)
        } else {
            (vgs_raw - vds_raw, -vds_raw, vbs_raw - vds_raw, true)
        };
        let vsb = -vbs;

        // Body effect + narrow-width (delta) + DIBL (eta)
        let sqrt_phi_vsb = (phi + vsb.max(-phi + 1e-12)).sqrt();
        let sqrt_phi = phi.sqrt();
        let gamma_w =
            gamma + delta * std::f64::consts::PI * 3.9e-11 / (4.0 * w * sqrt_phi_vsb.max(1e-6));
        let vth = if is_pmos {
            vto.abs() + gamma_w * (sqrt_phi - sqrt_phi_vsb) - eta * vds
        } else {
            vto + gamma_w * (sqrt_phi_vsb - sqrt_phi) - eta * vds
        };
        let vov = vgs - vth;

        // Mobility degradation: beta = beta0 / (1 + theta * vov)
        let beta = if theta > 0.0 && vov > 0.0 {
            beta0 / (1.0 + theta * vov)
        } else {
            beta0
        };

        // Saturation voltage with kappa (empirical)
        let vdsat = if kappa > 0.0 && vov > 0.0 {
            vov / (1.0 + kappa * vov)
        } else {
            vov
        };

        // Chain-rule derivatives for beta and vdsat w.r.t. vov (used in gm below).
        let d_beta_d_vov = if theta > 0.0 && vov > 0.0 {
            -beta0 * theta / (1.0 + theta * vov).powi(2)
        } else {
            0.0
        };
        let d_vdsat_d_vov = if kappa > 0.0 && vov > 0.0 {
            1.0 / (1.0 + kappa * vov).powi(2)
        } else {
            1.0
        };

        let (id, gm, gds) = if vov <= 0.0 {
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else if vds < vdsat {
            let id = beta * (vov * vds - 0.5 * vds * vds) * (1.0 + lambda * vds) + GDS_MIN * vds;
            // d(Id_lin)/d(vov) via product rule: beta depends on vov
            let gm_lin =
                beta * vds * (1.0 + lambda * vds) + (vov * vds - vds * vds * 0.5) * d_beta_d_vov;
            let gds = beta * (vov - vds) * (1.0 + lambda * vds)
                + beta * (vov * vds - 0.5 * vds * vds) * lambda
                + GDS_MIN;
            (id, gm_lin, gds)
        } else {
            let id = 0.5 * beta * vdsat * vdsat * (1.0 + lambda * vds) + GDS_MIN * vds;
            // d(Id_sat)/d(vov): both beta and vdsat depend on vov
            let gm_sat = (1.0 + lambda * vds)
                * (d_beta_d_vov * vdsat * vdsat * 0.5 + beta * vdsat * d_vdsat_d_vov);
            let gds = 0.5 * beta * vdsat * vdsat * lambda + GDS_MIN;
            (id, gm_sat, gds)
        };

        let gmb = if sqrt_phi_vsb > 1e-6 {
            gm * gamma_w / (2.0 * sqrt_phi_vsb)
        } else {
            0.0
        };
        // DIBL contribution to output conductance: d(Vth)/d(Vds) = -eta → gds gain
        let gds_eta = gm * eta;
        let gds_total = gds + gds_eta;

        let id_signed = if reversed { -sign * id } else { sign * id };

        // Jacobian: when reversed, D/S columns swap (see MosfetLevel1).
        let (g_dd, g_dg, g_ds, g_db, g_sd, g_sg, g_ss, g_sb) = if reversed {
            (
                gm + gds_total + gmb,
                -gm,
                -gds_total,
                -gmb,
                -(gm + gds_total + gmb),
                gm,
                gds_total,
                gmb,
            )
        } else {
            (
                gds_total,
                gm,
                -(gm + gds_total + gmb),
                gmb,
                -gds_total,
                -gm,
                gm + gds_total + gmb,
                -gmb,
            )
        };

        let (g_junc, q_junc, g_jac_junc, c_junc) = mos_body_junctions(voltages, params, is_pmos);
        let (q_gate, c_gate) =
            mos_gate_caps(voltages, params, w, l, vov, vds, vdsat.max(0.0), reversed);
        let mut q_total = smallvec![q_gate[0], q_gate[1], q_gate[2], q_gate[3]];
        let mut g_total = smallvec![id_signed, 0.0, -id_signed, 0.0];
        for i in 0..4 {
            g_total[i] += g_junc[i];
            q_total[i] += q_junc[i];
        }

        let mut g_entries = smallvec![
            (0, 0, g_dd),
            (0, 1, g_dg),
            (0, 2, g_ds),
            (0, 3, g_db),
            (2, 0, g_sd),
            (2, 1, g_sg),
            (2, 2, g_ss),
            (2, 3, g_sb),
            (3u8, 3u8, GDS_MIN),
        ];
        g_entries.extend(g_jac_junc);

        let mut c_total = c_gate;
        c_total.extend(c_junc);

        DeviceEval {
            g: g_total,
            q: q_total,
            G: g_entries,
            C: c_total,
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::MosfetN3
    }
}

/// MOSFET Level 6 (Sakurai-Newton power-law model): 4-terminal device.
///
/// Pin 0 = drain, Pin 1 = gate, Pin 2 = source, Pin 3 = bulk.
/// Uses Id = (W/L) * ko * Vov^mk with a tanh-based smooth linear-to-saturation transition.
/// Parameters: `ko` (conductance coefficient, default 1e-5), `mk` (current exponent, default 2.0),
///             `vto`, `lambda`, `w`, `l`.
#[derive(Debug, Clone, Copy)]
pub struct MosfetLevel6;

impl DeviceModel for MosfetLevel6 {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let ko = params.get("ko").or_else(|| params.get("kp")).unwrap_or(1e-5);
        let mk = params.get_or("mk", 2.0);
        let vto = params
            .get("vto")
            .or_else(|| params.get("vth0"))
            .unwrap_or(0.7);
        let lambda = params.get_or("lambda", 0.0);
        let w = params.get_or("w", 1e-6);
        let l = params.get_or("l", 1e-6);
        let ld = params.get_or("ld", 0.0);
        let leff = (l - 2.0 * ld).max(1e-9);

        let is_pmos = params.get_or("pmos", 0.0) != 0.0;
        let sign = if is_pmos { -1.0 } else { 1.0 };

        let vgs_raw = sign * (voltages[1] - voltages[2]);
        let vds_raw = sign * (voltages[0] - voltages[2]);

        // Source-drain swap when Vds < 0 (see MosfetLevel1 for full explanation).
        let (vgs, vds, reversed) = if vds_raw >= 0.0 {
            (vgs_raw, vds_raw, false)
        } else {
            (vgs_raw - vds_raw, -vds_raw, true)
        };

        let vth_eff = if is_pmos { vto.abs() } else { vto };
        let vov = vgs - vth_eff;

        let (id, gm, gds) = if vov <= 0.0 {
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else {
            let wl = w / leff;
            // Saturation current: id_sat = (W/L) * ko * Vov^mk
            let id_sat = wl * ko * vov.powf(mk);
            // Smooth linear→sat via tanh: id = id_sat * tanh(Vds/Vov) * (1 + lambda*Vds)
            let ratio = if vov > 1e-9 {
                (vds / vov).min(20.0)
            } else {
                20.0_f64
            };
            let thr = ratio.tanh();
            let sech2 = 1.0 - thr * thr;
            let id = id_sat * thr * (1.0 + lambda * vds) + GDS_MIN * vds;
            let gm = wl * ko * mk * vov.powf(mk - 1.0) * thr * (1.0 + lambda * vds);
            let gds = id_sat * sech2 / vov * (1.0 + lambda * vds) + id_sat * thr * lambda + GDS_MIN;
            (id, gm, gds)
        };

        let id_signed = if reversed { -sign * id } else { sign * id };

        // Jacobian: when reversed, D/S columns swap (see MosfetLevel1).
        let (g_dd, g_dg, g_ds, g_sd, g_sg, g_ss) = if reversed {
            (gm + gds, -gm, -gds, -(gm + gds), gm, gds)
        } else {
            (gds, gm, -(gm + gds), -gds, -gm, gm + gds)
        };

        let (g_junc, q_junc, g_jac_junc, c_junc) = mos_body_junctions(voltages, params, is_pmos);
        let (q_gate, c_gate) =
            mos_gate_caps(voltages, params, w, l, vov, vds, vov.max(0.0), reversed);
        let mut q_total = smallvec![q_gate[0], q_gate[1], q_gate[2], q_gate[3]];
        let mut g_total = smallvec![id_signed, 0.0, -id_signed, 0.0];
        for i in 0..4 {
            g_total[i] += g_junc[i];
            q_total[i] += q_junc[i];
        }

        let mut g_entries = smallvec![
            (0, 0, g_dd),
            (0, 1, g_dg),
            (0, 2, g_ds),
            (2, 0, g_sd),
            (2, 1, g_sg),
            (2, 2, g_ss),
            (3u8, 3u8, GDS_MIN),
        ];
        g_entries.extend(g_jac_junc);

        let mut c_total = c_gate;
        c_total.extend(c_junc);

        DeviceEval {
            g: g_total,
            q: q_total,
            G: g_entries,
            C: c_total,
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::MosfetN6
    }
}

// ── SIMD batch Level 1 MOSFET evaluation (4-wide f64x4) ──────────────────

use wide::{f64x4, CmpGe, CmpLe};

/// SoA (Structure of Arrays) input for 4 Level 1 MOSFETs evaluated in parallel.
#[derive(Debug, Clone)]
pub struct MosfetBatchInput {
    /// Gate-source voltages (already sign-flipped for PMOS, swapped for Vds<0).
    pub vgs: f64x4,
    /// Drain-source voltages (non-negative after swap).
    pub vds: f64x4,
    /// Bulk-source voltages.
    pub vbs: f64x4,
    /// Threshold voltage (VTO base, before body effect).
    pub vth0: f64x4,
    /// Transconductance parameter kp.
    pub kp: f64x4,
    /// Channel width.
    pub w: f64x4,
    /// Effective channel length (l - 2*ld, already clamped).
    pub leff: f64x4,
    /// Channel-length modulation factor.
    pub lambda: f64x4,
    /// Body-effect coefficient gamma.
    pub gamma: f64x4,
    /// Surface potential phi (clamped >= 0.1).
    pub phi: f64x4,
}

/// SoA output for 4 Level 1 MOSFETs.
#[derive(Debug, Clone)]
pub struct MosfetBatchOutput {
    /// Drain current (positive = conventional drain-to-source).
    pub ids: f64x4,
    /// Transconductance dId/dVgs.
    pub gm: f64x4,
    /// Output conductance dId/dVds.
    pub gds: f64x4,
    /// Body transconductance dId/dVbs.
    pub gmb: f64x4,
}

/// Evaluate 4 Level 1 (Shichman-Hodges) MOSFETs simultaneously using SIMD.
///
/// The caller is responsible for:
/// - Flipping voltage signs for PMOS (multiply by -1)
/// - Performing source-drain swap when Vds < 0 (so that `vds` is non-negative)
/// - Computing effective length `leff = (l - 2*ld).max(1e-9)`
///
/// This function implements the same arithmetic as `MosfetLevel1::eval` but
/// uses `f64x4` SIMD lanes to process 4 devices per call.  Region branching
/// (cutoff / linear / saturation) is handled via branchless SIMD select.
pub fn batch_eval_level1(input: &MosfetBatchInput) -> MosfetBatchOutput {
    let zero = f64x4::ZERO;
    let one = f64x4::splat(1.0);
    let half = f64x4::splat(0.5);
    let gds_min = f64x4::splat(GDS_MIN);
    let tiny = f64x4::splat(1e-12);
    let phi_floor = f64x4::splat(1e-6);

    let beta = input.kp * input.w / input.leff;

    // Body effect: Vth = vth0 + gamma * (sqrt(phi + Vsb) - sqrt(phi))
    // vsb = -vbs
    let vsb = zero - input.vbs;
    // Clamp (phi + vsb) >= tiny to avoid sqrt of negative
    let phi_plus_vsb = (input.phi + vsb).max(tiny);
    let sqrt_phi_vsb = phi_plus_vsb.sqrt();
    let sqrt_phi = input.phi.sqrt();
    let vth = input.vth0 + input.gamma * (sqrt_phi_vsb - sqrt_phi);
    let vov = input.vgs - vth;

    // ── Cutoff: Ids = GDS_MIN * Vds ──────────────────────────────────────
    let ids_cutoff = gds_min * input.vds;
    let gm_cutoff = zero;
    let gds_cutoff = gds_min;

    // ── Linear (triode): Ids = beta * (Vov*Vds - Vds²/2) * (1+lambda*Vds) + GDS_MIN*Vds
    let lam_term = one + input.lambda * input.vds; // (1 + lambda * Vds)
    let vov_vds = vov * input.vds;
    let lin_core = vov_vds - half * input.vds * input.vds;
    let ids_lin = beta * lin_core * lam_term + gds_min * input.vds;
    let gm_lin = beta * input.vds;
    let gds_lin = beta * (vov - input.vds)
        + input.lambda * beta * input.vds * (vov - half * input.vds)
        + gds_min;

    // ── Saturation: Ids = beta/2 * Vov² * (1+lambda*Vds) + GDS_MIN*Vds
    let vov_sq = vov * vov;
    let ids_sat = half * beta * vov_sq * lam_term + gds_min * input.vds;
    let gm_sat = beta * vov;
    let gds_sat = half * beta * vov_sq * input.lambda + gds_min;

    // ── Region selection via SIMD masks ───────────────────────────────────
    // cutoff: vov <= 0
    let in_cutoff = vov.simd_le(zero);
    // saturation: vds >= vov (and not cutoff)
    let in_sat = input.vds.simd_ge(vov);

    // First select between linear and saturation (for non-cutoff devices)
    let ids_active = f64x4_select(in_sat, ids_sat, ids_lin);
    let gm_active = f64x4_select(in_sat, gm_sat, gm_lin);
    let gds_active = f64x4_select(in_sat, gds_sat, gds_lin);

    // Then select between cutoff and active
    let ids = f64x4_select(in_cutoff, ids_cutoff, ids_active);
    let gm = f64x4_select(in_cutoff, gm_cutoff, gm_active);
    let gds = f64x4_select(in_cutoff, gds_cutoff, gds_active);

    // Body-effect transconductance: gmb = gm * gamma / (2 * sqrt(phi + Vsb))
    let denom = f64x4::splat(2.0) * sqrt_phi_vsb;
    let gmb_raw = gm * input.gamma / denom;
    let gmb = f64x4_select(sqrt_phi_vsb.simd_le(phi_floor), zero, gmb_raw);

    MosfetBatchOutput { ids, gm, gds, gmb }
}

/// Branchless SIMD select: for each lane, returns `if_true` when `mask` is
/// all-ones (true) and `if_false` when `mask` is all-zeros (false).
///
/// `wide` represents comparison results as `f64x4` where true lanes are
/// all-ones (NaN bit pattern) and false lanes are all-zeros.  We exploit
/// this by using bitwise AND/OR to blend the two operands.
#[inline(always)]
fn f64x4_select(mask: f64x4, if_true: f64x4, if_false: f64x4) -> f64x4 {
    // wide::f64x4 comparison returns f64x4 with all-ones bits for true lanes.
    // We use blend: result = (mask & if_true) | (!mask & if_false)
    (mask & if_true) | ((!mask) & if_false)
}

/// Extract the `i`-th lane (0..3) from an `f64x4`.
#[inline(always)]
fn f64x4_lane(v: f64x4, i: usize) -> f64 {
    let arr: [f64; 4] = v.into();
    arr[i]
}

/// Pack scalar parameters for up to 4 Level 1 MOSFETs into a
/// [`MosfetBatchInput`], evaluate, and return individual
/// [`MosfetBatchOutput`] lanes.
///
/// `devices` is a slice of `(vgs, vds, vbs, vth0, kp, w, leff, lambda, gamma, phi)`.
/// Length must be 1..=4; unused lanes are zeroed (cutoff, harmless).
pub fn batch_eval_level1_scatter(
    devices: &[(f64, f64, f64, f64, f64, f64, f64, f64, f64, f64)],
) -> Vec<(f64, f64, f64, f64)> {
    assert!(!devices.is_empty() && devices.len() <= 4);

    let mut vgs = [0.0f64; 4];
    let mut vds = [0.0f64; 4];
    let mut vbs = [0.0f64; 4];
    let mut vth0 = [0.0f64; 4];
    let mut kp = [0.0f64; 4];
    let mut w = [0.0f64; 4];
    let mut leff = [1e-9f64; 4]; // avoid div-by-zero in unused lanes
    let mut lambda = [0.0f64; 4];
    let mut gamma = [0.0f64; 4];
    let mut phi = [0.1f64; 4]; // clamped minimum

    for (i, d) in devices.iter().enumerate() {
        vgs[i] = d.0;
        vds[i] = d.1;
        vbs[i] = d.2;
        vth0[i] = d.3;
        kp[i] = d.4;
        w[i] = d.5;
        leff[i] = d.6;
        lambda[i] = d.7;
        gamma[i] = d.8;
        phi[i] = d.9;
    }

    let inp = MosfetBatchInput {
        vgs: f64x4::new(vgs),
        vds: f64x4::new(vds),
        vbs: f64x4::new(vbs),
        vth0: f64x4::new(vth0),
        kp: f64x4::new(kp),
        w: f64x4::new(w),
        leff: f64x4::new(leff),
        lambda: f64x4::new(lambda),
        gamma: f64x4::new(gamma),
        phi: f64x4::new(phi),
    };

    let out = batch_eval_level1(&inp);

    devices
        .iter()
        .enumerate()
        .map(|(i, _)| {
            (
                f64x4_lane(out.ids, i),
                f64x4_lane(out.gm, i),
                f64x4_lane(out.gds, i),
                f64x4_lane(out.gmb, i),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cap_entry(eval: &DeviceEval, row: u8, col: u8) -> f64 {
        eval.C
            .iter()
            .filter(|(r, c, _)| *r == row && *c == col)
            .map(|(_, _, v)| *v)
            .sum()
    }

    fn nmos_params() -> ParamMap {
        let mut p = ParamMap::new();
        p.set("kp", 2e-5);
        p.set("vth", 0.7);
        p.set("lambda", 0.02);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        p
    }

    #[test]
    fn nmos_cutoff() {
        let m = MosfetLevel1;
        let params = nmos_params();
        let eval = m.eval(&[5.0, 0.3, 0.0, 0.0][..], &params);
        // In cutoff, id = GDS_MIN * Vds = 1e-12 * 5 = 5e-12
        assert!(
            (eval.g[0]).abs() < 1e-10,
            "cutoff current {} too large",
            eval.g[0]
        );
    }

    #[test]
    fn nmos_saturation() {
        let m = MosfetLevel1;
        let params = nmos_params();
        let eval = m.eval(&[5.0, 2.0, 0.0, 0.0][..], &params);
        assert!(eval.g[0] > 0.0);
    }

    #[test]
    fn nmos_linear() {
        let m = MosfetLevel1;
        let params = nmos_params();
        let eval = m.eval(&[0.5, 2.0, 0.0, 0.0][..], &params);
        assert!(eval.g[0] > 0.0);
    }

    #[test]
    fn nmos_current_conservation() {
        let m = MosfetLevel1;
        let params = nmos_params();
        let eval = m.eval(&[3.0, 2.0, 0.0, 0.0][..], &params);
        assert!((eval.g[0] + eval.g[2]).abs() < 1e-20);
    }

    // ── Source-drain swap tests (Vds < 0) ────────────────────────────────

    #[test]
    fn nmos_negative_vds_reverses_current() {
        // When Vd < Vs, current should flow from source to drain (negative Id).
        let m = MosfetLevel1;
        let params = nmos_params();
        // Normal: Vd=3, Vg=2, Vs=0 → positive Id (drain→source)
        let eval_normal = m.eval(&[3.0, 2.0, 0.0, 0.0][..], &params);
        assert!(eval_normal.g[0] > 0.0, "normal: Id should be positive");

        // Swapped: Vd=0, Vg=2, Vs=3 → Vds_raw = 0-3 = -3, triggers swap
        // Effective: vgs' = Vgd = 2-0 = 2, vds' = 3
        // After swap, id is positive internally but negated → Id at pin 0 is negative
        let eval_swapped = m.eval(&[0.0, 2.0, 3.0, 0.0][..], &params);
        assert!(
            eval_swapped.g[0] < 0.0,
            "reversed Vds: Id at drain should be negative, got {}",
            eval_swapped.g[0]
        );
    }

    #[test]
    fn nmos_negative_vds_current_conservation() {
        // KCL: current into drain + current into source = 0
        let m = MosfetLevel1;
        let params = nmos_params();
        let eval = m.eval(&[0.0, 2.0, 3.0, 0.0][..], &params);
        assert!(
            (eval.g[0] + eval.g[2]).abs() < 1e-20,
            "KCL violated: Id={} + Is={} != 0",
            eval.g[0],
            eval.g[2]
        );
    }

    #[test]
    fn nmos_swap_symmetry() {
        // Swapping drain and source physically should give equal-magnitude,
        // opposite-sign drain current (for symmetric Vgs conditions).
        let m = MosfetLevel1;
        let params = nmos_params();
        // Case A: Vd=3, Vg=2, Vs=0 → Vgs=2, Vds=3
        let eval_a = m.eval(&[3.0, 2.0, 0.0, 0.0][..], &params);
        // Case B: Vd=0, Vg=2, Vs=3 → swap triggers, effective Vgs'=Vgd=2, Vds'=3
        let eval_b = m.eval(&[0.0, 2.0, 3.0, 0.0][..], &params);
        // Magnitudes should be equal (same effective operating point)
        let id_a = eval_a.g[0];
        let id_b = eval_b.g[0];
        assert!(
            (id_a + id_b).abs() < 1e-15,
            "swap symmetry: |Id_normal| should equal |Id_reversed|: {} vs {}",
            id_a,
            id_b
        );
    }

    #[test]
    fn nmos_negative_vds_cutoff() {
        // Vds < 0 but device in cutoff (Vgd < Vth after swap)
        let m = MosfetLevel1;
        let params = nmos_params();
        // Vd=-1, Vg=0.3, Vs=0 → Vds_raw = -1, swap → vgs'=Vgd=0.3-(-1)=1.3... no
        // Actually: Vd=0, Vg=0.3, Vs=3 → Vds_raw = 0-3 = -3, swap → vgs'=Vgd=0.3-0=0.3
        // 0.3 < Vth=0.7 → cutoff
        let eval = m.eval(&[0.0, 0.3, 3.0, 0.0][..], &params);
        assert!(
            eval.g[0].abs() < 1e-10,
            "reversed cutoff: current should be ~0, got {}",
            eval.g[0]
        );
    }

    #[test]
    fn pmos_negative_vds_swap() {
        // PMOS in reversed condition
        let m = MosfetLevel1;
        let mut p = nmos_params();
        p.set("pmos", 1.0);
        p.set("vth", -0.7); // PMOS threshold

        // Normal PMOS: Vd=0, Vg=0, Vs=3.3, Vb=3.3
        // sign=-1: vgs = -1*(0-3.3) = 3.3, vds = -1*(0-3.3) = 3.3 → normal operation
        let eval_normal = m.eval(&[0.0, 0.0, 3.3, 3.3][..], &p);
        assert!(
            eval_normal.g[0] < 0.0,
            "PMOS normal: Id at drain should be negative (current into drain), got {}",
            eval_normal.g[0]
        );

        // KCL conservation
        assert!(
            (eval_normal.g[0] + eval_normal.g[2]).abs() < 1e-20,
            "PMOS KCL violated"
        );
    }

    // ── Level 2 tests ──────────────────────────────────────────────────────

    #[test]
    fn mosfet_l2_body_effect() {
        // With gamma=0.5 and Vbs=-1 (Vsb=+1), Vth should exceed VTO=0.7
        let m = MosfetLevel2;
        let mut p = ParamMap::new();
        p.set("kp", 2e-5);
        p.set("vto", 0.7);
        p.set("gamma", 0.5);
        p.set("phi", 0.6);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // voltages: [Vd, Vg, Vs, Vb] = [3.0, 2.0, 0.0, -1.0]
        // Vbs = -1.0 → Vsb = +1.0 → body effect raises Vth
        let eval_body = m.eval(&[3.0, 2.0, 0.0, -1.0][..], &p);
        // Without body effect (Vbs=0):
        let eval_no_body = m.eval(&[3.0, 2.0, 0.0, 0.0][..], &p);
        // Higher Vth → lower overdrive → lower current
        assert!(
            eval_body.g[0] < eval_no_body.g[0],
            "body effect should reduce Id: {} >= {}",
            eval_body.g[0],
            eval_no_body.g[0]
        );
    }

    #[test]
    fn mosfet_l2_no_body_effect() {
        // gamma=0 → Level 2 should behave identically to Level 1
        let m1 = MosfetLevel1;
        let m2 = MosfetLevel2;
        let mut p = ParamMap::new();
        p.set("kp", 2e-5);
        p.set("vto", 0.7);
        p.set("gamma", 0.0);
        p.set("phi", 0.6);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // saturation
        let e1 = m1.eval(&[5.0, 2.0, 0.0, 0.0][..], &p);
        let e2 = m2.eval(&[5.0, 2.0, 0.0, 0.0][..], &p);
        assert!(
            (e1.g[0] - e2.g[0]).abs() < 1e-15,
            "L2 with gamma=0 should match L1: {} vs {}",
            e1.g[0],
            e2.g[0]
        );
    }

    // ── Level 3 tests ──────────────────────────────────────────────────────

    #[test]
    fn mosfet_l3_dibl() {
        // DIBL: eta > 0 lowers Vth → higher overdrive → higher Id at the same Vds.
        // Compare eta=0 vs eta>0 at the same operating point to isolate the DIBL effect
        // from region changes (kappa can move the saturation boundary).
        let m = MosfetLevel3;
        let mut p_no_dibl = ParamMap::new();
        p_no_dibl.set("kp", 2e-5);
        p_no_dibl.set("vto", 0.7);
        p_no_dibl.set("gamma", 0.0);
        p_no_dibl.set("phi", 0.6);
        p_no_dibl.set("eta", 0.0);
        p_no_dibl.set("w", 10e-6);
        p_no_dibl.set("l", 1e-6);

        let mut p_dibl = p_no_dibl.clone();
        p_dibl.set("eta", 0.1);

        // Same voltages: Vds=2 gives eta*Vds = 0.2V threshold reduction
        let eval_no_dibl = m.eval(&[2.0, 2.0, 0.0, 0.0][..], &p_no_dibl);
        let eval_dibl = m.eval(&[2.0, 2.0, 0.0, 0.0][..], &p_dibl);
        assert!(
            eval_dibl.g[0] > eval_no_dibl.g[0],
            "DIBL should boost Id: with eta={} vs without={}",
            eval_dibl.g[0],
            eval_no_dibl.g[0]
        );
    }

    #[test]
    fn mosfet_l3_current_conservation() {
        let m = MosfetLevel3;
        let mut p = ParamMap::new();
        p.set("kp", 2e-5);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        let eval = m.eval(&[3.0, 2.0, 0.0, 0.0][..], &p);
        assert!((eval.g[0] + eval.g[2]).abs() < 1e-20);
    }

    #[test]
    fn mosfet_l2_adds_meyer_gate_charge_when_tox_present() {
        let m = MosfetLevel2;
        let mut p = nmos_params();
        p.set("tox", 10e-9);
        p.set("cgso", 2e-10);
        p.set("cgdo", 3e-10);
        p.set("cgbo", 1e-10);

        let eval = m.eval(&[1.0, 2.0, 0.0, 0.0][..], &p);

        assert!(eval.q[1].abs() > 0.0, "gate charge should be present");
        assert!(
            cap_entry(&eval, 1, 1) > 0.0,
            "gate capacitance should stamp C(1,1)"
        );
    }

    #[test]
    fn mosfet_l3_honors_overlap_caps_without_tox() {
        let m = MosfetLevel3;
        let mut p = nmos_params();
        p.set("eta", 0.0);
        p.set("cgso", 2e-10);
        p.set("cgdo", 3e-10);
        p.set("cgbo", 4e-10);

        let eval = m.eval(&[1.0, 2.0, 0.0, -0.5][..], &p);

        assert!(
            eval.q[1].abs() > 0.0,
            "overlap-only gate charge should be present"
        );
        assert!(
            cap_entry(&eval, 1, 3) < 0.0,
            "gate-bulk overlap should stamp C(1,3)"
        );
    }

    #[test]
    fn mosfet_l1_body_diode_conducts_when_forward_biased() {
        let m = MosfetLevel1;
        let mut p = nmos_params();
        p.set("is", 1e-12);

        let eval = m.eval(&[0.0, 0.0, 0.0, 0.8][..], &p);

        assert!(
            eval.g[3] > 0.0,
            "forward body diode should source bulk current"
        );
        assert!(
            eval.g[0] < 0.0,
            "drain-body diode should sink current at drain"
        );
        assert!(
            eval.g[2] < 0.0,
            "source-body diode should sink current at source"
        );
    }

    #[test]
    fn mosfet_l1_body_junction_charge_includes_depletion_and_tt() {
        let m = MosfetLevel1;
        let mut p = nmos_params();
        p.set("cbs", 1e-12);
        p.set("cbd", 2e-12);
        p.set("pb", 0.8);
        p.set("mj", 0.5);
        p.set("tt", 1e-9);
        p.set("is", 1e-12);

        let eval = m.eval(&[0.1, 0.0, 0.0, 0.6][..], &p);

        assert!(
            eval.q[3].abs() > 0.0,
            "bulk junction charge should be present"
        );
        assert!(
            cap_entry(&eval, 3, 3) > 0.0,
            "bulk junction capacitance should stamp C(3,3)"
        );
    }

    // ── Level 6 tests ──────────────────────────────────────────────────────

    #[test]
    fn mosfet_l6_saturation() {
        let m = MosfetLevel6;
        let mut p = ParamMap::new();
        p.set("ko", 1e-5);
        p.set("mk", 2.0);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        let eval = m.eval(&[5.0, 2.0, 0.0, 0.0][..], &p);
        assert!(
            eval.g[0] > 0.0,
            "Level 6 should produce current in saturation"
        );
    }

    #[test]
    fn mosfet_l6_current_conservation() {
        let m = MosfetLevel6;
        let mut p = ParamMap::new();
        p.set("ko", 1e-5);
        p.set("mk", 2.0);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        let eval = m.eval(&[3.0, 2.0, 0.0, 0.0][..], &p);
        assert!((eval.g[0] + eval.g[2]).abs() < 1e-20);
    }

    #[test]
    fn test_level6_has_gate_caps_with_tox() {
        let mut p = ParamMap::new();
        p.set("tox", 1e-8);
        p.set("ko", 2e-4);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // NMOS biased in saturation: Vgs=1.5V, Vds=2V, Vbs=0
        let voltages = [2.0, 1.5, 0.0, 0.0];
        let eval = MosfetLevel6.eval(&voltages, &p);
        // Gate cap entry (1,1) should be non-zero with tox set
        let cgg = cap_entry(&eval, 1, 1);
        assert!(cgg > 0.0, "Level6 should have gate cap with tox, got {cgg}");
    }

    #[test]
    fn test_level6_default_tox_gives_gate_caps() {
        let mut p = ParamMap::new();
        p.set("ko", 2e-4);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // Without explicit tox, default 100nm is used (ngspice behaviour).
        // Gate caps should be non-zero from the default Cox.
        let voltages = [2.0, 1.5, 0.0, 0.0];
        let eval = MosfetLevel6.eval(&voltages, &p);
        let cgg = cap_entry(&eval, 1, 1);
        assert!(cgg > 0.0, "Level6 with default tox should have non-zero gate cap, got {cgg}");
    }

    #[test]
    fn test_level6_gate_caps_with_overlap() {
        let mut p = ParamMap::new();
        p.set("ko", 2e-4);
        p.set("cgso", 1e-10); // overlap capacitance per unit width
        p.set("cgdo", 1e-10);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        let voltages = [2.0, 1.5, 0.0, 0.0];
        let eval = MosfetLevel6.eval(&voltages, &p);
        // Cgs overlap = cgso*W = 1e-10 * 10e-6 = 1e-15 F
        let cgg = cap_entry(&eval, 1, 1);
        assert!(cgg > 0.0, "Level6 with cgso/cgdo should have overlap gate cap, got {cgg}");
    }

    #[test]
    fn test_level6_pmos_gate_caps() {
        let mut p = ParamMap::new();
        p.set("tox", 1e-8);
        p.set("ko", 2e-4);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        p.set("pmos", 1.0);
        p.set("vto", -0.7); // PMOS threshold negative
        // PMOS in saturation: Vgs=-1.5V, Vds=-2V → applied as positives in level6
        let voltages = [-2.0, -1.5, 0.0, 0.0];
        let eval = MosfetLevel6.eval(&voltages, &p);
        let cgg = cap_entry(&eval, 1, 1);
        assert!(cgg > 0.0, "Level6 PMOS should have gate cap with tox, got {cgg}");
    }

    #[test]
    fn test_level6_off_state_zero_current() {
        let mut p = ParamMap::new();
        p.set("ko", 2e-4);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        p.set("vto", 0.7);
        // Below threshold: Vgs=0.3V < Vth=0.7V
        let voltages = [1.0, 0.3, 0.0, 0.0];
        let eval = MosfetLevel6.eval(&voltages, &p);
        // Current should be near-zero (only gds_min * vds)
        let id = eval.g[0]; // drain current
        assert!(id.abs() < 1e-6, "Level6 off-state current should be near zero, got {id}");
    }

    #[test]
    fn test_level1_gate_caps_in_saturation() {
        let mut p = nmos_params();
        p.set("tox", 5e-9);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // Saturation: Vgs=2V, Vds=3V (Vdsat ≈ Vgs-Vth = 1.3V)
        let voltages = [3.0, 2.0, 0.0, 0.0];
        let eval = MosfetLevel1.eval(&voltages, &p);
        // In saturation, Cgs = 2/3 * Cox, Cgd ≈ 0
        let cgg = cap_entry(&eval, 1, 1);
        assert!(cgg > 0.0, "Level1 in saturation should have gate cap, got {cgg}");
    }

    #[test]
    fn test_level3_gate_caps_in_triode() {
        let mut p = ParamMap::new();
        p.set("kp", 2e-4);
        p.set("vto", 0.5);
        p.set("tox", 8e-9);
        p.set("w", 5e-6);
        p.set("l", 0.5e-6);
        // Triode: Vgs=2V, Vds=0.5V (Vdsat > Vds)
        let voltages = [0.5, 2.0, 0.0, 0.0];
        let eval = MosfetLevel3.eval(&voltages, &p);
        let cgg = cap_entry(&eval, 1, 1);
        assert!(cgg > 0.0, "Level3 in triode should have gate cap, got {cgg}");
    }

    // ── Additional MOSFET Level 1 physics tests ──────────────────────────────

    /// Cutoff at VGS=0: VGS < VTO so only GDS_MIN leakage flows.
    #[test]
    fn nmos_l1_cutoff_vgs_zero() {
        let m = MosfetLevel1;
        // KP=110u, VTO=0.7, W=10u, L=1u
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // VGS=0, VDS=1 → cutoff
        let eval = m.eval(&[1.0, 0.0, 0.0, 0.0], &p);
        // Only GDS_MIN * VDS = 1e-12 A leakage
        assert!(
            eval.g[0].abs() < 1e-9,
            "cutoff at VGS=0: Id={} should be ~GDS_MIN leakage",
            eval.g[0]
        );
    }

    /// Cutoff at VGS=0.5 (below VTO=0.7): still cutoff.
    #[test]
    fn nmos_l1_cutoff_vgs_below_vto() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // VGS=0.5 < VTO=0.7, VDS=1 → cutoff
        let eval = m.eval(&[1.0, 0.5, 0.0, 0.0], &p);
        assert!(
            eval.g[0].abs() < 1e-9,
            "sub-threshold: Id={} should be near zero",
            eval.g[0]
        );
    }

    /// Linear region: VGS=2.0, VDS=0.5 (< VGS-VTO=1.3): linear I-V.
    /// Id = KP*(W/L)*(VGS-VTO - VDS/2)*VDS
    #[test]
    fn nmos_l1_linear_analytic() {
        let m = MosfetLevel1;
        let kp = 110e-6_f64;
        let vto = 0.7_f64;
        let w = 10e-6_f64;
        let l = 1e-6_f64;
        let vgs = 2.0_f64;
        let vds = 0.5_f64;
        let mut p = ParamMap::new();
        p.set("kp", kp);
        p.set("vto", vto);
        p.set("w", w);
        p.set("l", l);
        let eval = m.eval(&[vds, vgs, 0.0, 0.0], &p);
        let beta = kp * w / l;
        let vov = vgs - vto;
        let id_expected = beta * (vov * vds - 0.5 * vds * vds);
        let id_actual = eval.g[0];
        let rel_err = (id_actual - id_expected).abs() / id_expected.abs().max(1e-30);
        assert!(
            rel_err < 1e-4,
            "linear Id: got {id_actual:.6e}, expected {id_expected:.6e}, rel_err={rel_err:.2e}"
        );
    }

    /// Saturation region: VGS=2.0, VDS=2.0 (> VGS-VTO=1.3): saturation current.
    /// Id_sat = KP/2 * (W/L) * (VGS-VTO)^2
    #[test]
    fn nmos_l1_saturation_analytic() {
        let m = MosfetLevel1;
        let kp = 110e-6_f64;
        let vto = 0.7_f64;
        let w = 10e-6_f64;
        let l = 1e-6_f64;
        let vgs = 2.0_f64;
        let vds = 2.0_f64;
        let mut p = ParamMap::new();
        p.set("kp", kp);
        p.set("vto", vto);
        p.set("w", w);
        p.set("l", l);
        let eval = m.eval(&[vds, vgs, 0.0, 0.0], &p);
        let beta = kp * w / l;
        let vov = vgs - vto;
        let id_expected = 0.5 * beta * vov * vov;
        let id_actual = eval.g[0];
        let rel_err = (id_actual - id_expected).abs() / id_expected.abs().max(1e-30);
        assert!(
            rel_err < 1e-4,
            "sat Id: got {id_actual:.6e}, expected {id_expected:.6e}, rel_err={rel_err:.2e}"
        );
    }

    /// Saturation with lambda: Id increases with VDS due to channel-length modulation.
    #[test]
    fn nmos_l1_lambda_modulation() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        p.set("lambda", 0.1);
        let vgs = 2.0_f64;
        // Both bias points in saturation (VDS > VGS-VTO=1.3)
        let eval_lo = m.eval(&[2.0, vgs, 0.0, 0.0], &p);
        let eval_hi = m.eval(&[4.0, vgs, 0.0, 0.0], &p);
        assert!(
            eval_hi.g[0] > eval_lo.g[0],
            "lambda: Id should increase with VDS: lo={} hi={}",
            eval_lo.g[0],
            eval_hi.g[0]
        );
    }

    /// PMOS saturation: VGS=-2.0, VDS=-2.0 with pmos=1 and VTO=-0.7.
    /// Drain current should be negative (current flows from source to drain).
    #[test]
    fn pmos_l1_saturation_current_sign() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 60e-6);
        p.set("vto", -0.7);
        p.set("pmos", 1.0);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // PMOS: Vd=0, Vg=0, Vs=3.3, Vb=3.3 → VGS=-3.3, VDS=-3.3, |VGS|>|VTO|
        let eval = m.eval(&[0.0, 0.0, 3.3, 3.3], &p);
        assert!(
            eval.g[0] < 0.0,
            "PMOS: Id at drain should be negative (into drain), got {}",
            eval.g[0]
        );
        // Magnitude should be significant
        assert!(
            eval.g[0].abs() > 1e-6,
            "PMOS: Id magnitude should be significant, got {}",
            eval.g[0].abs()
        );
    }

    /// PMOS vs NMOS symmetry: PMOS with same |voltages| should have same magnitude.
    #[test]
    fn pmos_nmos_current_magnitude_symmetric() {
        let m = MosfetLevel1;
        let kp = 110e-6_f64;
        let vto_n = 0.7_f64;

        // NMOS: Vd=2, Vg=2, Vs=0, Vb=0
        let mut pn = ParamMap::new();
        pn.set("kp", kp);
        pn.set("vto", vto_n);
        pn.set("w", 10e-6);
        pn.set("l", 1e-6);
        let eval_nmos = m.eval(&[2.0, 2.0, 0.0, 0.0], &pn);

        // PMOS: Vd=-2, Vg=-2, Vs=0, Vb=0 → VGS=-2, VDS=-2, |VTO|=0.7
        let mut pp = ParamMap::new();
        pp.set("kp", kp);
        pp.set("vto", -vto_n);
        pp.set("pmos", 1.0);
        pp.set("w", 10e-6);
        pp.set("l", 1e-6);
        let eval_pmos = m.eval(&[-2.0, -2.0, 0.0, 0.0], &pp);

        // Both should be in the same operating region with equal magnitudes
        assert!(
            (eval_nmos.g[0].abs() - eval_pmos.g[0].abs()).abs() / eval_nmos.g[0].abs() < 1e-4,
            "NMOS/PMOS magnitude symmetry: nmos={} pmos={}",
            eval_nmos.g[0],
            eval_pmos.g[0]
        );
    }

    /// Body effect: gamma=0.4, VBS=-1.0 → higher Vth → less Id.
    #[test]
    fn nmos_l1_body_effect_reduces_current() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("gamma", 0.4);
        p.set("phi", 0.6);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // VGS=2, VDS=2, VBS=0 (no body effect)
        let eval_no_body = m.eval(&[2.0, 2.0, 0.0, 0.0], &p);
        // VGS=2, VDS=2, VBS=-1 (body reverse-biased → Vth increases → less Id)
        let eval_body = m.eval(&[2.0, 2.0, 0.0, -1.0], &p);
        assert!(
            eval_body.g[0] < eval_no_body.g[0],
            "body effect should reduce Id: with_body={} no_body={}",
            eval_body.g[0],
            eval_no_body.g[0]
        );
    }

    /// Gate caps in inversion (saturation): with tox, Cgs ≈ 2/3*Cox, Cgd ≈ 0.
    #[test]
    fn nmos_l1_gate_caps_saturation_region() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("tox", 10e-9);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // Saturation: VGS=2V, VDS=3V (VDS > VGS-VTO = 1.3V)
        let eval = m.eval(&[3.0, 2.0, 0.0, 0.0], &p);
        let cgs = cap_entry(&eval, 1, 2).abs(); // |C[gate,source]|
        let cgd = cap_entry(&eval, 1, 0).abs(); // |C[gate,drain]|
        assert!(cgs > 0.0, "Cgs should be non-zero in saturation");
        // In saturation: Cgs >> Cgd
        assert!(
            cgs > cgd * 3.0,
            "in saturation Cgs ({cgs:.3e}) should be >> Cgd ({cgd:.3e})"
        );
    }

    /// Gate caps in triode: with tox, Cgs ≈ Cgd ≈ Cox/2.
    #[test]
    fn nmos_l1_gate_caps_triode_region() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("tox", 10e-9);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        // Triode: VGS=2V, VDS=0.5V (VDS < VGS-VTO=1.3V)
        let eval = m.eval(&[0.5, 2.0, 0.0, 0.0], &p);
        let cgs = cap_entry(&eval, 1, 2).abs();
        let cgd = cap_entry(&eval, 1, 0).abs();
        assert!(cgs > 0.0, "Cgs should be non-zero in triode");
        assert!(cgd > 0.0, "Cgd should be non-zero in triode");
        // In triode Ward-Dutton model: Cgs ≈ Cgd ≈ Cox/2 (exact at Vds→0).
        // At Vds=0.5V, Vov=1.3V the ratio deviates to ≈1.12 — allow 15%.
        let ratio = cgs / cgd;
        assert!(
            (ratio - 1.0).abs() < 0.15,
            "in triode Cgs/Cgd should be ≈ 1, got {ratio:.3}"
        );
    }

    /// KCL always holds: Id + Is + Ibulk = 0 (ignoring gate which is infinite impedance).
    #[test]
    fn nmos_l1_kcl_all_regions() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);

        let test_pts: &[[f64; 4]] = &[
            [1.0, 0.0, 0.0, 0.0],   // cutoff
            [0.5, 2.0, 0.0, 0.0],   // linear
            [3.0, 2.0, 0.0, 0.0],   // saturation
            [3.0, 2.0, 0.0, -0.5],  // saturation with body
        ];
        for v in test_pts {
            let eval = m.eval(v, &p);
            // sum of drain, source (gate g[1] is zero always for MOSFET resistive)
            let sum = eval.g[0] + eval.g[2];
            assert!(
                sum.abs() < 1e-20,
                "KCL violated at {:?}: Id+Is={sum:.3e}",
                v
            );
        }
    }

    /// Level 1 Jacobian finite-difference check in saturation.
    #[test]
    fn nmos_l1_jacobian_fd_saturation() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        let v = [3.0_f64, 2.0, 0.0, 0.0];
        let h = 1e-6_f64;
        let e0 = m.eval(&v, &p);
        // FD: perturb Vg (pin 1), check dId/dVg ≈ G[0,1]
        let ep = m.eval(&[v[0], v[1] + h, v[2], v[3]], &p);
        let fd_gm = (ep.g[0] - e0.g[0]) / h;
        let analytic_gm = e0.G.iter().find(|(r, c, _)| *r == 0 && *c == 1)
            .map(|(_, _, v)| *v).unwrap_or(0.0);
        let rel_err = (fd_gm - analytic_gm).abs() / analytic_gm.abs().max(1e-20);
        assert!(
            rel_err < 1e-3,
            "Jacobian dId/dVg: fd={fd_gm:.6e} analytic={analytic_gm:.6e} err={rel_err:.2e}"
        );
    }

    /// Level 1 Jacobian finite-difference: dId/dVds in linear region.
    #[test]
    fn nmos_l1_jacobian_fd_linear() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        let v = [0.5_f64, 2.0, 0.0, 0.0];
        let h = 1e-6_f64;
        let e0 = m.eval(&v, &p);
        // FD: perturb Vd (pin 0), check dId/dVd ≈ G[0,0]
        let ep = m.eval(&[v[0] + h, v[1], v[2], v[3]], &p);
        let fd_gds = (ep.g[0] - e0.g[0]) / h;
        let analytic_gds = e0.G.iter().find(|(r, c, _)| *r == 0 && *c == 0)
            .map(|(_, _, v)| *v).unwrap_or(0.0);
        let rel_err = (fd_gds - analytic_gds).abs() / analytic_gds.abs().max(1e-20);
        assert!(
            rel_err < 1e-3,
            "Jacobian dId/dVd: fd={fd_gds:.6e} analytic={analytic_gds:.6e} err={rel_err:.2e}"
        );
    }

    /// Saturation boundary: at VDS = VGS-VTO, linear and saturation models agree.
    #[test]
    fn nmos_l1_saturation_boundary_continuity() {
        let m = MosfetLevel1;
        let mut p = ParamMap::new();
        p.set("kp", 110e-6);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        let vgs = 2.0_f64;
        let vdsat = vgs - 0.7; // = 1.3 V
        // Just below and just above the saturation boundary
        let eval_lin = m.eval(&[vdsat - 1e-4, vgs, 0.0, 0.0], &p);
        let eval_sat = m.eval(&[vdsat + 1e-4, vgs, 0.0, 0.0], &p);
        // Current should be very close at the boundary
        let rel_diff = (eval_sat.g[0] - eval_lin.g[0]).abs() / eval_lin.g[0].abs().max(1e-30);
        assert!(
            rel_diff < 1e-2,
            "continuity at Vdsat: lin={} sat={} rel_diff={rel_diff:.3e}",
            eval_lin.g[0],
            eval_sat.g[0]
        );
    }

    /// Default parameters: eval with empty ParamMap should not panic, produce finite results.
    #[test]
    fn nmos_l1_default_params_finite() {
        let m = MosfetLevel1;
        let p = ParamMap::new();
        let eval = m.eval(&[1.0, 1.0, 0.0, 0.0], &p);
        assert!(eval.g[0].is_finite());
        assert!(eval.g[2].is_finite());
        assert!((eval.g[0] + eval.g[2]).abs() < 1e-20);
    }

    /// W/L scaling: doubling W doubles Id in saturation.
    #[test]
    fn nmos_l1_wl_scaling_doubles_id() {
        let m = MosfetLevel1;
        let mut p1 = ParamMap::new();
        p1.set("kp", 110e-6);
        p1.set("vto", 0.7);
        p1.set("w", 10e-6);
        p1.set("l", 1e-6);
        let mut p2 = p1.clone();
        p2.set("w", 20e-6); // double W

        let eval1 = m.eval(&[3.0, 2.0, 0.0, 0.0], &p1);
        let eval2 = m.eval(&[3.0, 2.0, 0.0, 0.0], &p2);
        let ratio = eval2.g[0] / eval1.g[0];
        assert!(
            (ratio - 2.0).abs() < 1e-6,
            "doubling W should double Id: ratio={ratio:.6}"
        );
    }

    // ── SIMD batch Level 1 tests ──────────────────────────────────────────

    /// Helper: evaluate a single Level 1 MOSFET via the scalar path and return
    /// (ids, gm, gds, gmb) for comparison with the SIMD batch path.
    fn scalar_level1(
        vgs: f64, vds: f64, vbs: f64, vth0: f64, kp: f64,
        w: f64, leff: f64, lambda: f64, gamma: f64, phi: f64,
    ) -> (f64, f64, f64, f64) {
        let beta = kp * w / leff;
        let vsb = -vbs;
        let sqrt_phi_vsb = (phi + vsb.max(-phi + 1e-12)).sqrt();
        let sqrt_phi = phi.sqrt();
        let vth = vth0 + gamma * (sqrt_phi_vsb - sqrt_phi);
        let vov = vgs - vth;

        let (id, gm, gds) = if vov <= 0.0 {
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else if vds < vov {
            let id = beta * (vov * vds - 0.5 * vds * vds) * (1.0 + lambda * vds) + GDS_MIN * vds;
            let gm = beta * vds;
            let gds = beta * (vov - vds)
                + lambda * beta * vds * (vov - 0.5 * vds)
                + GDS_MIN;
            (id, gm, gds)
        } else {
            let id = 0.5 * beta * vov * vov * (1.0 + lambda * vds) + GDS_MIN * vds;
            let gm = beta * vov;
            let gds = 0.5 * beta * vov * vov * lambda + GDS_MIN;
            (id, gm, gds)
        };

        let gmb = if sqrt_phi_vsb > 1e-6 {
            gm * gamma / (2.0 * sqrt_phi_vsb)
        } else {
            0.0
        };

        (id, gm, gds, gmb)
    }

    #[test]
    fn simd_batch_matches_scalar_saturation() {
        // 4 devices all in saturation (Vds > Vov)
        let params: Vec<(f64, f64, f64, f64, f64, f64, f64, f64, f64, f64)> = vec![
            (2.0, 5.0, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),
            (1.5, 3.0, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),
            (3.0, 5.0, 0.0, 0.7, 1e-4, 5e-6,  2e-6, 0.01, 0.0, 0.6),
            (1.0, 2.0, 0.0, 0.5, 5e-5, 20e-6, 1e-6, 0.0,  0.0, 0.6),
        ];
        let simd_results = batch_eval_level1_scatter(&params);
        for (i, p) in params.iter().enumerate() {
            let (ids_s, gm_s, gds_s, gmb_s) = scalar_level1(
                p.0, p.1, p.2, p.3, p.4, p.5, p.6, p.7, p.8, p.9,
            );
            let (ids_v, gm_v, gds_v, gmb_v) = simd_results[i];
            assert!((ids_s - ids_v).abs() < 1e-15 * ids_s.abs().max(1e-30),
                "lane {i} ids: scalar={ids_s:.6e} simd={ids_v:.6e}");
            assert!((gm_s - gm_v).abs() < 1e-15 * gm_s.abs().max(1e-30),
                "lane {i} gm: scalar={gm_s:.6e} simd={gm_v:.6e}");
            assert!((gds_s - gds_v).abs() < 1e-15 * gds_s.abs().max(1e-30),
                "lane {i} gds: scalar={gds_s:.6e} simd={gds_v:.6e}");
            assert!((gmb_s - gmb_v).abs() < 1e-15,
                "lane {i} gmb: scalar={gmb_s:.6e} simd={gmb_v:.6e}");
        }
    }

    #[test]
    fn simd_batch_matches_scalar_linear() {
        // 4 devices all in linear region (Vds < Vov)
        let params: Vec<(f64, f64, f64, f64, f64, f64, f64, f64, f64, f64)> = vec![
            (2.0, 0.5, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),
            (3.0, 0.3, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),
            (1.5, 0.1, 0.0, 0.7, 1e-4, 5e-6,  2e-6, 0.01, 0.0, 0.6),
            (2.0, 0.2, 0.0, 0.5, 5e-5, 20e-6, 1e-6, 0.0,  0.0, 0.6),
        ];
        let simd_results = batch_eval_level1_scatter(&params);
        for (i, p) in params.iter().enumerate() {
            let (ids_s, gm_s, gds_s, gmb_s) = scalar_level1(
                p.0, p.1, p.2, p.3, p.4, p.5, p.6, p.7, p.8, p.9,
            );
            let (ids_v, gm_v, gds_v, gmb_v) = simd_results[i];
            assert!((ids_s - ids_v).abs() < 1e-15 * ids_s.abs().max(1e-30),
                "lane {i} ids: scalar={ids_s:.6e} simd={ids_v:.6e}");
            assert!((gm_s - gm_v).abs() < 1e-15 * gm_s.abs().max(1e-30),
                "lane {i} gm: scalar={gm_s:.6e} simd={gm_v:.6e}");
            assert!((gds_s - gds_v).abs() < 1e-15 * gds_s.abs().max(1e-30),
                "lane {i} gds: scalar={gds_s:.6e} simd={gds_v:.6e}");
            assert!((gmb_s - gmb_v).abs() < 1e-15,
                "lane {i} gmb: scalar={gmb_s:.6e} simd={gmb_v:.6e}");
        }
    }

    #[test]
    fn simd_batch_matches_scalar_cutoff() {
        // 4 devices all in cutoff (Vgs < Vth)
        let params: Vec<(f64, f64, f64, f64, f64, f64, f64, f64, f64, f64)> = vec![
            (0.3, 5.0, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),
            (0.0, 3.0, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),
            (0.5, 1.0, 0.0, 0.7, 1e-4, 5e-6,  2e-6, 0.01, 0.0, 0.6),
            (0.2, 2.0, 0.0, 0.5, 5e-5, 20e-6, 1e-6, 0.0,  0.0, 0.6),
        ];
        let simd_results = batch_eval_level1_scatter(&params);
        for (i, p) in params.iter().enumerate() {
            let (ids_s, gm_s, gds_s, gmb_s) = scalar_level1(
                p.0, p.1, p.2, p.3, p.4, p.5, p.6, p.7, p.8, p.9,
            );
            let (ids_v, gm_v, gds_v, gmb_v) = simd_results[i];
            assert!((ids_s - ids_v).abs() < 1e-20,
                "lane {i} ids: scalar={ids_s:.6e} simd={ids_v:.6e}");
            assert!((gm_s - gm_v).abs() < 1e-20,
                "lane {i} gm: scalar={gm_s:.6e} simd={gm_v:.6e}");
            assert!((gds_s - gds_v).abs() < 1e-20,
                "lane {i} gds: scalar={gds_s:.6e} simd={gds_v:.6e}");
            assert!((gmb_s - gmb_v).abs() < 1e-20,
                "lane {i} gmb: scalar={gmb_s:.6e} simd={gmb_v:.6e}");
        }
    }

    #[test]
    fn simd_batch_mixed_regions() {
        // 4 devices in different regions: cutoff, linear, saturation, saturation
        let params: Vec<(f64, f64, f64, f64, f64, f64, f64, f64, f64, f64)> = vec![
            (0.3, 5.0, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),  // cutoff
            (2.0, 0.5, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),  // linear
            (2.0, 5.0, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),  // saturation
            (1.5, 3.0, 0.0, 0.7, 1e-4, 5e-6,  2e-6, 0.01, 0.0, 0.6),  // saturation
        ];
        let simd_results = batch_eval_level1_scatter(&params);
        for (i, p) in params.iter().enumerate() {
            let (ids_s, gm_s, gds_s, gmb_s) = scalar_level1(
                p.0, p.1, p.2, p.3, p.4, p.5, p.6, p.7, p.8, p.9,
            );
            let (ids_v, gm_v, gds_v, gmb_v) = simd_results[i];
            let tol = 1e-14;
            assert!((ids_s - ids_v).abs() < tol * ids_s.abs().max(1e-30),
                "lane {i} ids: scalar={ids_s:.6e} simd={ids_v:.6e}");
            assert!((gm_s - gm_v).abs() < tol * gm_s.abs().max(1e-30),
                "lane {i} gm: scalar={gm_s:.6e} simd={gm_v:.6e}");
            assert!((gds_s - gds_v).abs() < tol * gds_s.abs().max(1e-30),
                "lane {i} gds: scalar={gds_s:.6e} simd={gds_v:.6e}");
            assert!((gmb_s - gmb_v).abs() < tol,
                "lane {i} gmb: scalar={gmb_s:.6e} simd={gmb_v:.6e}");
        }
    }

    #[test]
    fn simd_batch_with_body_effect() {
        // Test with non-zero gamma (body effect active)
        let params: Vec<(f64, f64, f64, f64, f64, f64, f64, f64, f64, f64)> = vec![
            (2.0, 5.0, -1.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.5, 0.6), // Vsb=+1
            (2.0, 0.5,  0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.5, 0.6), // Vsb=0
            (2.0, 5.0, -2.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.3, 0.6), // Vsb=+2
            (1.5, 3.0, -0.5, 0.5, 1e-4, 5e-6,  2e-6, 0.01, 0.8, 0.6), // Vsb=+0.5
        ];
        let simd_results = batch_eval_level1_scatter(&params);
        for (i, p) in params.iter().enumerate() {
            let (ids_s, gm_s, gds_s, gmb_s) = scalar_level1(
                p.0, p.1, p.2, p.3, p.4, p.5, p.6, p.7, p.8, p.9,
            );
            let (ids_v, gm_v, gds_v, gmb_v) = simd_results[i];
            let tol = 1e-14;
            assert!((ids_s - ids_v).abs() < tol * ids_s.abs().max(1e-30),
                "lane {i} ids: scalar={ids_s:.6e} simd={ids_v:.6e}");
            assert!((gm_s - gm_v).abs() < tol * gm_s.abs().max(1e-30),
                "lane {i} gm: scalar={gm_s:.6e} simd={gm_v:.6e}");
            assert!((gds_s - gds_v).abs() < tol * gds_s.abs().max(1e-30),
                "lane {i} gds: scalar={gds_s:.6e} simd={gds_v:.6e}");
            assert!((gmb_s - gmb_v).abs() < tol * gmb_s.abs().max(1e-30),
                "lane {i} gmb: scalar={gmb_s:.6e} simd={gmb_v:.6e}");
        }
    }

    #[test]
    fn simd_batch_partial_fill() {
        // Only 2 devices — remaining lanes should be harmless
        let params: Vec<(f64, f64, f64, f64, f64, f64, f64, f64, f64, f64)> = vec![
            (2.0, 5.0, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),
            (1.5, 0.3, 0.0, 0.7, 2e-5, 10e-6, 1e-6, 0.02, 0.0, 0.6),
        ];
        let simd_results = batch_eval_level1_scatter(&params);
        assert_eq!(simd_results.len(), 2);
        for (i, p) in params.iter().enumerate() {
            let (ids_s, _, _, _) = scalar_level1(
                p.0, p.1, p.2, p.3, p.4, p.5, p.6, p.7, p.8, p.9,
            );
            let (ids_v, _, _, _) = simd_results[i];
            assert!((ids_s - ids_v).abs() < 1e-14 * ids_s.abs().max(1e-30),
                "lane {i} ids mismatch: scalar={ids_s:.6e} simd={ids_v:.6e}");
        }
    }
}
