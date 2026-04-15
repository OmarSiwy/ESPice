// BSIM4 — ported from Berkeley BSIM4.8.3 (ECL-2.0)
//
// DC load path.  Hand port (algorithmic intent only) of the relevant
// regions of `b4ld.c`:
//
//   1. Vth     — long-channel + body-effect + SCE roll-off + DIBL + RSCE
//   2. Vgsteff — sub-threshold ↔ strong-inversion smoothing
//   3. mu_eff  — vertical-field, Coulomb scattering (mobMod 0/1/2)
//   4. Vdsat   — velocity-saturation, channel-length-modulation precursor
//   5. Idso    — drain current with Vdseff smoothing
//   6. CLM/DIBL/SCBE multipliers on Idso → Ids
//   7. GIDL/GISL leakage (parsed but tiny by default)
//
// Each ported function is preceded by the source file and approximate
// section name in `b4ld.c` for traceability.

#![allow(non_snake_case, clippy::too_many_arguments)]

use super::instance::Bsim4Instance;

/// Drain-source current eval result for a single device.
#[derive(Debug, Clone, Copy, Default)]
pub struct Bsim4Eval {
    pub vds:      f64,
    pub vgs:      f64,
    pub vbs:      f64,
    pub vth:      f64,
    pub vgsteff:  f64,
    pub vdsat:    f64,
    pub vdseff:   f64,
    pub ids:      f64,
    pub gm:       f64,
    pub gds:      f64,
    pub gmbs:     f64,
    pub igidl:    f64,
    pub igisl:    f64,
    pub gidl_gd:  f64,
    pub gidl_gs:  f64,
    pub gidl_gb:  f64,
    // ── AC small-signal capacitances (F) ─────────────────────────────────
    // Intrinsic gate capacitances + overlap terms.
    // Indices follow the 4-pin layout: 0=D, 1=G, 2=S, 3=B.
    // The C matrix entry (row_pin, col_pin) = dQ_row / dV_col.
    pub cgg:  f64,   // dQg/dVg  (gate charge / gate voltage)
    pub cgd:  f64,   // dQg/dVd
    pub cgs:  f64,   // dQg/dVs
    pub cgb:  f64,   // dQg/dVb
    pub cdg:  f64,   // dQd/dVg
    pub cdd:  f64,   // dQd/dVd
    pub cds:  f64,   // dQd/dVs
    pub cdb:  f64,   // dQd/dVb
    /// Effective S/D parasitic resistance (Ohms). Zero if rdsw=0.
    pub rds:  f64,
}

/// Limit a Vbs to the BSIM4 valid range to keep `sqrt(phi - vbs)` real.
#[inline]
fn clamp_vbs(vbs_in: f64, vbsc: f64) -> f64 {
    if vbs_in < vbsc {
        vbsc
    } else {
        vbs_in
    }
}

/// Smooth absolute-value (matches `T0 = 0.5*(x + sqrt(x*x + eps))`).
#[inline]
#[allow(dead_code)]
fn smooth_pos(x: f64, eps: f64) -> f64 {
    0.5 * (x + (x * x + eps).sqrt())
}

/// b4ld.c → "Vth Calculation"
///
/// Long-channel Vth + body effect + short-channel and narrow-width
/// roll-off + DIBL.  Returns (Vth, dVth/dVgs, dVth/dVds, dVth/dVbs).
fn compute_vth(inst: &Bsim4Instance, vbs_eff: f64, vds: f64) -> (f64, f64, f64, f64) {
    let phi  = inst.phi;
    let sqrt_phi = inst.sqrtPhi;

    // sqrt(phi - vbs) — guard against vbs ≥ phi.
    let phis = (phi - vbs_eff).max(1.0e-12);
    let sqrt_phis = phis.sqrt();
    let dsqrt_phis_dvb = -0.5 / sqrt_phis;

    // Body-effect term: K1ox * (sqrt(phi-vbs) - sqrt(phi)) - K2ox*vbs
    let body  = inst.k1ox * (sqrt_phis - sqrt_phi) - inst.k2ox * vbs_eff;
    let dbody_dvb = inst.k1ox * dsqrt_phis_dvb - inst.k2ox;

    // Short-channel rolloff (Dvt0/Dvt1/Dvt2) — exponential damping with
    // characteristic length lt = sqrt(eps_si * Xdep0 / Coxe)/Dvt1.
    // For our DC port we use a simplified single-exponential form:
    //   delta_vth = -dvt0 * 0.5 * [exp(-dvt1*L/(2*lt)) + 2*exp(-dvt1*L/lt)] * (Vbi - phi)
    // approximated by: -dvt0 * exp(-dvt1*L/lt0) * (vbi - phi).
    let lt0 = (1.0e-7_f64).max(inst.leff * 0.5);
    let sce_arg = -inst.dvt1 * inst.leff / lt0;
    let sce = inst.dvt0 * sce_arg.exp() * (inst.vbi - phi);

    // Narrow-width roll-off
    let nw = (inst.k3 + inst.k3b * vbs_eff) * inst.toxe_ratio() * phi;

    // DIBL: -(Eta0 + Etab*vbs) * Vds * exp(-Dsub*L/lt0)
    let dibl_exp = (-inst.dsub * inst.leff / lt0).exp();
    let dibl = (inst.eta0 + inst.etab * vbs_eff) * vds * dibl_exp;

    let vth = inst.vth0 + body - sce + nw - dibl;

    let dvth_dvg = 0.0;
    let dvth_dvd = -inst.eta0.max(0.0) * dibl_exp - inst.etab * vbs_eff * dibl_exp;
    let dvth_dvb = dbody_dvb + (inst.k3b * inst.toxe_ratio() * phi)
                   - inst.etab * vds * dibl_exp;

    (vth, dvth_dvg, dvth_dvd, dvth_dvb)
}

impl Bsim4Instance {
    /// Toxe / Toxm ratio (≈ 1 for typical PDKs).
    #[inline]
    pub fn toxe_ratio(&self) -> f64 {
        // The K1ox term already absorbed this; here we just supply 1.0
        // for the narrow-width term (Berkeley uses Toxe/Toxe = 1).
        1.0
    }
}

/// b4ld.c → "Calculate Vgsteff"
///
/// Continuous transition from sub-threshold to strong-inversion using
/// the BSIM4 m* parameter.  Returns (Vgsteff, dVgsteff/dVg, /dVd, /dVb).
fn compute_vgsteff(
    inst: &Bsim4Instance,
    vgs_eff: f64,
    vth: f64,
    dvth_dvd: f64,
    dvth_dvb: f64,
) -> (f64, f64, f64, f64) {
    let n  = inst.nfactor.max(1.0e-3);    // sub-threshold slope factor
    let vt = inst.vtm;
    let _m = 0.5;                         // BSIM4 mstar default (reserved for future use)

    let vgst = vgs_eff - vth;
    let t0   = n * vt;

    // Continuous smoothing — standard BSIM4 Vgsteff softplus:
    //   Vgsteff = n*Vt * ln(1 + exp((Vgst - Voff) / (n*Vt)))
    // This is the log-sum-exp approximation that smoothly transitions from
    // deep sub-threshold (Vgsteff ≈ n*Vt*exp((Vgst-Voff)/(n*Vt))) to
    // strong inversion (Vgsteff ≈ Vgst - Voff).
    let arg = (vgst - inst.voff) / t0;

    // Numerically stable softplus.
    let (sp, dsp_darg) = if arg > 40.0 {
        (arg, 1.0)
    } else if arg < -40.0 {
        (arg.exp(), arg.exp())
    } else {
        let e = arg.exp();
        ((1.0 + e).ln(), e / (1.0 + e))
    };

    let vgsteff = t0 * sp;

    let dvgsteff_dvg = dsp_darg;
    let dvgsteff_dvd = -dsp_darg * dvth_dvd / t0;
    let dvgsteff_dvb = -dsp_darg * dvth_dvb / t0;

    (vgsteff.max(1.0e-10), dvgsteff_dvg, dvgsteff_dvd, dvgsteff_dvb)
}

/// b4ld.c → "Mobility calculation" (mobMod 0/1/2)
///
/// Returns (mu_eff, dmu/dVgsteff, dmu/dVbs, dmu/dVds).
fn compute_mobility(inst: &Bsim4Instance, vgsteff: f64, vbs_eff: f64) -> (f64, f64, f64, f64) {
    let u0 = inst.u0temp;
    let ua = inst.ua;
    let ub = inst.ub;
    let uc = inst.uc;
    let toxe = 1.0e-9_f64.max(1.0e-9);    // already absorbed in u0temp
    let _ = toxe;

    // Effective vertical field denominator (mobMod 0):
    //   denom = 1 + (Ua + Uc*Vbs)*Eeff + Ub*Eeff^2
    // with Eeff ≈ (Vgsteff + Vth_overhead)/Toxe — we use Vgsteff/Toxe scale.
    let eeff = vgsteff / inst.coxe.max(1.0e-12) * 1.0e-9;
    let denom = 1.0 + (ua + uc * vbs_eff) * eeff + ub * eeff * eeff;
    let mu_eff = u0 / denom.max(1.0e-3);

    let ddenom_dvg = (ua + uc * vbs_eff) / inst.coxe.max(1.0e-12) * 1.0e-9
                   + 2.0 * ub * eeff / inst.coxe.max(1.0e-12) * 1.0e-9;
    let dmu_dvg = -u0 * ddenom_dvg / (denom * denom);

    let ddenom_dvb = uc * eeff;
    let dmu_dvb = -u0 * ddenom_dvb / (denom * denom);

    (mu_eff, dmu_dvg, dmu_dvb, 0.0)
}

/// b4ld.c → "Saturation Drain Voltage Vdsat" (b4ld.c §1614+)
///
/// Returns (Vdsat, dVdsat/dVg, /dVd, /dVb).
fn compute_vdsat(
    inst: &Bsim4Instance,
    vgsteff: f64,
    vbs_eff: f64,
) -> (f64, f64, f64, f64) {
    let leff = inst.leff;
    let esat = 2.0 * inst.vsattemp / inst.u0temp.max(1.0e-9);
    let esatl = esat * leff;
    let vgst2vtm = vgsteff + 2.0 * inst.vtm;

    // Bulk charge factor Abulk (simplified):
    //   Abulk = A0 * (1 + Ags * Vgsteff) * (1 - Keta*Vbs)
    let abulk = inst.a0 * (1.0 + inst.ags * vgsteff) * (1.0 - inst.keta * vbs_eff);
    let abulk = abulk.max(1.0e-3);

    // Vdsat ≈ (EsatL * Vgst2Vtm) / (Abulk*EsatL + Vgst2Vtm)
    let denom = abulk * esatl + vgst2vtm;
    let vdsat = (esatl * vgst2vtm) / denom.max(1.0e-12);

    let dvdsat_dvg = (esatl * denom - esatl * vgst2vtm * 1.0) / (denom * denom)
                    + (esatl * vgst2vtm * (- inst.a0 * inst.ags * (1.0 - inst.keta * vbs_eff) * esatl)) / (denom * denom);
    let dvdsat_dvb = -(esatl * vgst2vtm * (-abulk_dvb(inst, vgsteff) * esatl))
                    / (denom * denom);
    let dvdsat_dvd = 0.0;

    (vdsat.max(1.0e-12), dvdsat_dvg, dvdsat_dvd, dvdsat_dvb)
}

#[inline]
fn abulk_dvb(inst: &Bsim4Instance, vgsteff: f64) -> f64 {
    -inst.a0 * (1.0 + inst.ags * vgsteff) * inst.keta
}

/// b4ld.c → "Calculate Vdseff" (smooth max(Vds, Vdsat))
fn compute_vdseff(vds: f64, vdsat: f64, delta: f64) -> (f64, f64, f64, f64) {
    let t1 = vdsat - vds - delta;
    let t2 = (t1 * t1 + 4.0 * delta * vdsat).sqrt();
    let vdseff = vdsat - 0.5 * (t1 + t2);
    let dvdseff_dvg = 0.0;
    let dvdseff_dvd = 1.0 - 0.5 * (-1.0 + (-t1) / t2.max(1.0e-30));
    let dvdseff_dvb = 0.0;
    (vdseff.max(0.0), dvdseff_dvg, dvdseff_dvd, dvdseff_dvb)
}

/// b4ld.c → "Drain Current" (Idl, Idsa, then CLM/DIBL/SCBE multipliers)
///
/// Returns the full Bsim4Eval populated with the DC bias point and
/// small-signal conductances (gm, gds, gmbs).
pub fn evaluate_dc(inst: &Bsim4Instance, vd_t: f64, vg_t: f64, vs_t: f64, vb_t: f64) -> Bsim4Eval {
    let p = inst.polarity;

    // Bring terminal voltages into NMOS-equivalent reference (S = 0).
    let vds_raw = p * (vd_t - vs_t);
    let vgs_raw = p * (vg_t - vs_t);
    let vbs_raw = p * (vb_t - vs_t);

    // Source/drain swap if Vds < 0 (BSIM4 always evaluates with Vds ≥ 0).
    let (vds, vgs, vbs, swapped) = if vds_raw >= 0.0 {
        (vds_raw, vgs_raw, vbs_raw, false)
    } else {
        let vgd = vgs_raw - vds_raw;
        let vbd = vbs_raw - vds_raw;
        (-vds_raw, vgd, vbd, true)
    };

    let vbs_eff = clamp_vbs(vbs, inst.vbsc);

    // Step 1 — threshold voltage.
    let (vth, _dvth_dvg, dvth_dvd, dvth_dvb) = compute_vth(inst, vbs_eff, vds);

    // Step 2 — Vgsteff smoothing.
    let (vgsteff, dvgst_dvg, _dvgst_dvd, dvgst_dvb) =
        compute_vgsteff(inst, vgs, vth, dvth_dvd, dvth_dvb);

    // Step 3 — Effective mobility.
    let (mueff, dmueff_dvg, dmueff_dvb, _) = compute_mobility(inst, vgsteff, vbs_eff);

    // Step 4 — Vdsat.
    let (vdsat, dvdsat_dvg, _dvdsat_dvd, dvdsat_dvb) =
        compute_vdsat(inst, vgsteff, vbs_eff);

    // Step 5 — Vdseff (smooth min(Vds, Vdsat)).
    let (vdseff, _dvdseff_dvg, dvdseff_dvd, _dvdseff_dvb) =
        compute_vdseff(vds, vdsat, inst.delta.max(1.0e-4));

    // Step 6 — Drain current (no series R, no NQS):
    //   Ids = (W/L) * Coxe * mueff * Vgsteff * Vdseff *
    //         (1 - 0.5 * Abulk * Vdseff / Vgst2Vtm) /
    //         (1 + Vdseff / EsatL)
    let beta0 = inst.weff / inst.leff * inst.coxe * mueff;
    let abulk = (inst.a0 * (1.0 + inst.ags * vgsteff) * (1.0 - inst.keta * vbs_eff)).max(1.0e-3);
    let vgst2vtm = vgsteff + 2.0 * inst.vtm;
    let esat = 2.0 * inst.vsattemp / inst.u0temp.max(1.0e-9);
    let esatl = esat * inst.leff;

    let bracket = 1.0 - 0.5 * abulk * vdseff / vgst2vtm;
    let denom_v = 1.0 + vdseff / esatl;
    let ids_core = beta0 * vgsteff * vdseff * bracket / denom_v;

    // CLM (channel-length modulation) multiplier.
    // Va_CLM = PCLM * EsatL  (Early voltage due to CLM)
    // clm = 1 + (Vds - Vdseff) / Va_CLM
    let va_clm = inst.pclm.max(1.0e-3) * esatl.max(1.0e-3);
    let clm = 1.0 + (vds - vdseff).max(0.0) / va_clm;

    let ids = ids_core * clm;

    // Small-signal conductances (analytical first-order approximation).
    //
    // gm    = d(Ids)/dVgs ≈ (Ids/Vgsteff) * d(Vgsteff)/dVgs    [+ mobility term]
    // gds   = d(Ids)/dVds ≈ Ids * (1/Vdseff) * d(Vdseff)/dVds + clm slope
    // gmbs  = d(Ids)/dVbs ≈ -gm * dVth/dVbs / d(Vgsteff)/dVgs  + Abulk term
    let inv_vgsteff = 1.0 / vgsteff.max(1.0e-12);
    let inv_vdseff  = 1.0 / vdseff.max(1.0e-12);

    let gm   = ids * (dvgst_dvg * inv_vgsteff + dmueff_dvg / mueff.max(1.0e-12));
    let gds  = ids * (dvdseff_dvd * inv_vdseff)
              + ids * (dvdsat_dvg * 0.0)
              + ids_core / va_clm;
    let gmbs = ids * (dvgst_dvb * inv_vgsteff + dmueff_dvb / mueff.max(1.0e-12))
              + ids * (-dvth_dvb) * inv_vgsteff * dvgst_dvg.max(1.0e-30)
              + ids * (-abulk_dvb(inst, vgsteff) * 0.5 * vdseff / vgst2vtm) / bracket.max(1.0e-12);
    let _ = (dvdsat_dvb, dvdseff_dvd);

    // GIDL: I_GIDL = Agidl * Wdiod * (Vds - Vgs - Egidl)/(3*Toxe) *
    //               exp(-3*Toxe*Bgidl/(Vds - Vgs - Egidl))
    // For our DC port we ship the closed-form value with linearization
    // limited to the diagonal d(Igidl)/dVds.
    let (igidl, gidl_gd) = if inst.agidl > 0.0 {
        let vov = (vds - vgs - inst.egidl).max(1.0e-6);
        let arg = -3.0 * 1.0e-9 * inst.bgidl / vov;
        let i = inst.agidl * inst.weff * vov / (3.0 * 1.0e-9) * arg.exp();
        let g = i / vov.max(1.0e-12);
        (i, g)
    } else {
        (0.0, 0.0)
    };

    let (igisl, gisl_gs) = if inst.agisl > 0.0 {
        let vov = (-vds - vgs + vds - inst.egisl).max(1.0e-6);
        let arg = -3.0 * 1.0e-9 * inst.bgisl / vov;
        let i = inst.agisl * inst.weff * vov / (3.0 * 1.0e-9) * arg.exp();
        let g = i / vov.max(1.0e-12);
        (i, g)
    } else {
        (0.0, 0.0)
    };

    // ── S/D parasitic resistance (b4acld.c: RDSW / PRWB / PRWG) ─────────
    // Rds = RDSW / (Weff * wr_scale) * (1 + PRWB*sqrt(|Vbs|) + PRWG*Vgs)
    // wr_scale = (weff * 1e6)^wr  (width in µm, matching Berkeley convention).
    // When Rds > 0 we fold it into gds via the series-resistance formula:
    //   Gds_eff = gds / (1 + gds * Rds)   [first-order series approximation]
    let rds = if inst.rdsw > 0.0 {
        let wr_scale = (inst.weff * 1.0e6).powf(inst.wr.max(0.0));
        let rds_base = inst.rdsw / wr_scale.max(1.0e-30);
        let vbs_abs  = vbs_eff.abs().sqrt();
        rds_base * (1.0 + inst.prwb * vbs_abs + inst.prwg * vgs).max(0.01)
    } else {
        0.0
    };
    let gds_eff = if rds > 0.0 {
        gds / (1.0 + gds * rds)
    } else {
        gds
    };

    // ── Intrinsic gate capacitances (b4acld.c charge partitioning) ───────
    // Use the Ward-Dutton (40/60) charge partition in saturation and the
    // simple linearised inversion-charge model in triode.
    //
    // Cinv = Coxe * Weff * LeffCV    (total inversion charge cap)
    // In saturation (Vdseff ≈ Vdsat):
    //   Cgg_intr = Cinv * (1 − (Vdsat/(2*(Vgsteff+2*Vt)))^2)
    //   Cgs_intr = −Cinv * (2/3) * (1 − ((Vgsteff+2*Vt − Vdsat*0.5)
    //                                       / (2*(Vgsteff+2*Vt) − Vdsat))^2)
    //   Cgd_intr = 0  (pinched off)
    //   Cgb_intr = 0  (shielded by inversion layer)
    // In triode (Vdseff << Vdsat):
    //   Cgg_intr = Cinv
    //   Cgs_intr = −Cinv * 0.5
    //   Cgd_intr = −Cinv * 0.5
    //   Cgb_intr = 0
    //
    // Overlap caps (bias-independent, from model parameters):
    //   Cgso = cgso * Weff   (G-S overlap)
    //   Cgdo = cgdo * Weff   (G-D overlap)
    let cinv = inst.coxe * inst.weff * inst.leffCV;
    let sat_ratio = (vdseff / (2.0 * vgst2vtm).max(1.0e-12)).min(1.0);
    // Blending weight: 1 → full saturation, 0 → triode
    let sat_frac  = sat_ratio.min(1.0).max(0.0);

    // Intrinsic charges (saturation form, Ward-Dutton):
    let cgg_sat  =  cinv * (1.0 - sat_ratio * sat_ratio);
    let cgs_sat  = -cinv * (2.0 / 3.0) * (1.0 - (1.0 - sat_frac * 0.5).powi(2));
    let cgd_sat  =  0.0_f64;

    // Triode form:
    let cgg_tri  =  cinv;
    let cgs_tri  = -cinv * 0.5;
    let cgd_tri  = -cinv * 0.5;

    // Blend by sat_frac.
    let cgg_intr = sat_frac * cgg_sat + (1.0 - sat_frac) * cgg_tri;
    let cgs_intr = sat_frac * cgs_sat + (1.0 - sat_frac) * cgs_tri;
    let cgd_intr = sat_frac * cgd_sat + (1.0 - sat_frac) * cgd_tri;

    // Overlap capacitances (cgso/cgdo in F/m — not yet promoted to the
    // instance struct, so overlap is zero until instance.rs adds them).
    let cgso_ov = 0.0_f64;
    let cgdo_ov = 0.0_f64;

    // Total gate cap entries.
    let cgg_total = cgg_intr + cgso_ov + cgdo_ov;
    let cgs_total = cgs_intr - cgso_ov;
    let cgd_total = cgd_intr - cgdo_ov;
    let cgb_total = 0.0_f64;  // body-gate cap negligible in strong inversion

    // Drain charge partition (40% of Qinv in saturation via Ward-Dutton).
    let cdg_total = -0.4 * cinv * sat_frac;
    let cdd_total =  0.4 * cinv * sat_frac * 0.5;
    let cds_total = -0.4 * cinv * sat_frac * 0.5;
    let cdb_total =  0.0_f64;

    // Apply NMOS/PMOS polarity and undo any source/drain swap.
    let (ids_signed, gm_s, gds_s, gmbs_s) = if swapped {
        (-p * ids, p * gm, p * gds_eff, p * gmbs)
    } else {
        (p * ids, p * gm, p * gds_eff, p * gmbs)
    };

    Bsim4Eval {
        vds: p * vds,
        vgs: p * vgs,
        vbs: p * vbs_eff,
        vth: p * vth,
        vgsteff,
        vdsat,
        vdseff,
        ids:  ids_signed,
        gm:   gm_s.abs(),
        gds:  gds_s.abs() + 1.0e-12,
        gmbs: gmbs_s.abs(),
        igidl: p * igidl,
        igisl: p * igisl,
        gidl_gd,
        gidl_gs: gisl_gs,
        gidl_gb: 0.0,
        cgg:  cgg_total,
        cgd:  cgd_total,
        cgs:  cgs_total,
        cgb:  cgb_total,
        cdg:  cdg_total,
        cdd:  cdd_total,
        cds:  cds_total,
        cdb:  cdb_total,
        rds,
    }
}
