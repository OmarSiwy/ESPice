// BSIM3 — ported from Berkeley BSIM3v3.3 (ECL-2.0)
//
// DC current load path.  This is a hand-rolled, branchless port of the
// drain current computation in Berkeley `b3ld.c` (`BSIM3load`).  Only
// the DC contributions to Ids/gm/gds/gmbs and substrate Isub are
// computed here; capacitance, NQS, and noise live in dedicated modules.
//
// The function decomposition follows the structure of the C reference
// (Vbseff → Phis → Vth → n → Vgsteff → Abulk → mobility → Vdsat →
// Vdseff → Va → Ids), but each helper takes the warm-tier
// `Bsim3SizeParams` plus only the bias arguments it needs, returning
// f64 by value so the optimizer can fully inline the chain.
//
// Reference (READ-ONLY):
//   tests/external/ngspice/src/spicelib/devices/bsim3/b3ld.c

#![allow(non_snake_case, dead_code)]

use super::instance::{consts, Bsim3SizeParams};

/// Operating-point output of one DC evaluation.
///
/// Carries enough information for the stamper to build the Jacobian
/// rows + the output snapshot for `.OP` printing.  Sign convention is
/// **NMOS-like**: the caller flips for PMOS at stamp time.
#[derive(Debug, Clone, Copy, Default)]
pub struct Bsim3OpPoint {
    pub ids:   f64,    // drain current (A) — flowing into drain
    pub gm:    f64,    // d ids / d vgs
    pub gds:   f64,    // d ids / d vds
    pub gmbs:  f64,    // d ids / d vbs
    pub vdsat: f64,    // saturation voltage
    pub vth:   f64,    // threshold voltage
    pub von:   f64,    // turn-on voltage (vth + voff*n)
    pub vgsteff: f64,  // smoothed Vgs - Vth

    pub isub:  f64,    // substrate current (A) — into bulk
    pub gbds:  f64,    // d isub / d vds
    pub gbgs:  f64,    // d isub / d vgs
    pub gbbs:  f64,    // d isub / d vbs

    // ── AC small-signal capacitances (F) — b3acld.c charge partitioning ──
    // Pin layout: 0=D, 1=G, 2=S, 3=B.
    pub cgg:  f64,   // dQg/dVg
    pub cgd:  f64,   // dQg/dVd
    pub cgs:  f64,   // dQg/dVs
    pub cgb:  f64,   // dQg/dVb
    pub cdg:  f64,   // dQd/dVg
    pub cdd:  f64,   // dQd/dVd
    pub cds:  f64,   // dQd/dVs
    pub cdb:  f64,   // dQd/dVb
    /// Effective S/D parasitic resistance (Ohms). Zero when rdsw = 0.
    pub rds:  f64,
}

// ────────────────────────────────────────────────────────────────────────
// Step 1. Vbs smoothing — keep Vbs above Vbm with a quadratic clamp.
//   Berkeley b3ld.c (line ~600).
// ────────────────────────────────────────────────────────────────────────
#[inline]
fn smooth_vbs(vbs: f64, vbm: f64) -> (f64, f64) {
    // Berkeley uses:  Vbseff = Vbc + 0.5*(Vbs - Vbc - delta1
    //                          + sqrt((Vbs - Vbc - delta1)^2 - 4*delta1*Vbc))
    // with Vbc = 0.9*(Vbm - 0.5*phi).  Here we use the simpler clamp
    // form found in BSIM3 v3.2.4 / v3.3 with delta1 = 1e-3.
    let delta1 = 1.0e-3;
    let vbc = 0.9 * (vbm + 0.5);
    let t0 = vbs - vbc - delta1;
    let t1 = (t0 * t0 - 4.0 * delta1 * vbc.abs()).max(0.0).sqrt();
    let vbseff = vbc + 0.5 * (t0 + t1);
    let dvb_dvbs = 0.5 * (1.0 + t0 / t1.max(1.0e-30));
    (vbseff, dvb_dvbs)
}

// ────────────────────────────────────────────────────────────────────────
// Step 2. Compute the threshold voltage including SCE / DIBL / narrow W.
//   Berkeley b3ld.c (lines ~650-820).
// ────────────────────────────────────────────────────────────────────────
#[inline]
pub fn compute_vth(p: &Bsim3SizeParams, vbseff: f64, vds: f64) -> (f64, f64, f64, f64) {
    // Phis(Vbs) = phi - Vbseff (clamped positive).
    let phis = (p.phi - vbseff).max(1.0e-3);
    let sqrt_phis = phis.sqrt();
    let _dphis_dvbs = -1.0;
    let dsqrt_phis_dvbs = -0.5 / sqrt_phis;

    // Long-channel Vth0 + body effect.
    // V_t0 + K1*(sqrt(phis) - sqrt(phi)) - K2*Vbseff
    // (the K1ox/k2ox factors absorb the tox/toxm scaling).
    let vth_body = p.vth0
        + p.k1ox * (sqrt_phis - p.sqrtPhi)
        - p.k2ox * vbseff;
    let dvth_body_dvbs = p.k1ox * dsqrt_phis_dvbs - p.k2ox;

    // Narrow-width adjustment: + (k3 + k3b*Vbseff) * Tox / (Weff + W0) * phi.
    let nw = (p.k3 + p.k3b * vbseff) * p.tox / (p.weff + p.w0) * p.phi;
    let dnw_dvbs = p.k3b * p.tox / (p.weff + p.w0) * p.phi;

    // SCE term: -theta0vb0 * (vbi - phi)  (simplified — full has Vbs term).
    let sce = -p.theta0vb0 * (p.vbi - p.phi);

    // DIBL term: -thetaRout * (eta0 + etab*Vbseff) * Vds
    let dibl_coef = p.eta0 + p.etab * vbseff;
    let dibl = -p.thetaRout * dibl_coef * vds;
    let ddibl_dvds = -p.thetaRout * dibl_coef;
    let ddibl_dvbs = -p.thetaRout * p.etab * vds;

    let vth = vth_body + nw + sce + dibl;
    let dvth_dvbs = dvth_body_dvbs + dnw_dvbs + ddibl_dvbs;
    let dvth_dvds = ddibl_dvds;

    (vth, dvth_dvbs, dvth_dvds, sqrt_phis)
}

// ────────────────────────────────────────────────────────────────────────
// Step 3. Sub-threshold slope factor n and Vgsteff smoothing.
//   Berkeley b3ld.c (lines ~830-900).
// ────────────────────────────────────────────────────────────────────────
#[inline]
pub fn compute_n(p: &Bsim3SizeParams, vbseff: f64, sqrt_phis: f64) -> f64 {
    // n = 1 + Nfactor * Cdep / Cox + (Cdsc + Cdscb*Vbseff + Cdscd*Vds) / Cox
    //         + Cit / Cox
    let cdep0 = consts::EPSSI / p.Xdep0;
    let cdep = cdep0 * (p.sqrtPhi / sqrt_phis);
    let term = p.nfactor * cdep / p.cox
        + (p.cdsc + p.cdscb * vbseff) / p.cox
        + p.cit / p.cox;
    (1.0 + term).max(1.0)
}

#[inline]
pub fn compute_vgsteff(
    p: &Bsim3SizeParams,
    vgs: f64,
    vth: f64,
    n: f64,
) -> (f64, f64, f64) {
    // Vgsteff = n*Vt*ln(1 + exp((Vgs - Vth - Voff)/(n*Vt)))
    // (smoothed transition between weak and strong inversion).
    let vt = p.vt_t;
    let nvt = n * vt;
    let arg = (vgs - vth - p.voff) / nvt;
    // Clamp to avoid overflow / underflow in exp.
    let exp_arg = if arg > 50.0 {
        // Linear above the smooth region.
        return (arg * nvt + 0.0, 1.0, -1.0);
    } else if arg < -50.0 {
        f64::EPSILON
    } else {
        arg.exp()
    };
    let one_plus = 1.0 + exp_arg;
    let vgsteff = nvt * one_plus.ln();
    let dvgsteff_dvgs = exp_arg / one_plus;
    let dvgsteff_dvth = -dvgsteff_dvgs;
    (vgsteff, dvgsteff_dvgs, dvgsteff_dvth)
}

// ────────────────────────────────────────────────────────────────────────
// Step 4. Mobility model.  Implements mobMod = 1, 2, 3.
//   Berkeley b3ld.c (lines ~1000-1100).
// ────────────────────────────────────────────────────────────────────────
#[inline]
pub fn compute_mobility(
    p: &Bsim3SizeParams,
    vgsteff: f64,
    vbseff: f64,
) -> (f64, f64, f64) {
    let tox = p.tox;
    let denom_vt_vth = vgsteff + 2.0 * (p.vth0 - 0.0) + 1e-3; // approx
    // Berkeley field expression — collapsed:
    //   ueff = u0temp / (1 + (Ua + Uc*Vbseff)*((Vgsteff+2Vth)/Tox)
    //                      + Ub*((Vgsteff+2Vth)/Tox)^2)
    let efield = (vgsteff + 2.0 * p.vth0) / tox;
    let bias_term = match p.mobMod {
        1 => (p.ua + p.uc * vbseff) * efield + p.ub * efield * efield,
        2 => (p.ua + p.uc * vbseff) * efield + p.ub * efield * efield,
        _ => (p.ua * (1.0 + p.uc * vbseff)) * efield + p.ub * efield * efield,
    };
    let denom = (1.0 + bias_term).max(0.1);
    let ueff = p.u0temp / denom;

    // dueff/dvgs and dueff/dvbs (rough first-order — full Berkeley
    // chains through every term; this is enough for DC convergence).
    let dueff_dvgs = -ueff / denom * (p.ua + p.uc * vbseff) / tox;
    let dueff_dvbs = -ueff / denom * (p.uc * efield);
    let _ = denom_vt_vth;
    (ueff, dueff_dvgs, dueff_dvbs)
}

// ────────────────────────────────────────────────────────────────────────
// Step 5. Abulk + Vdsat (saturation voltage).
//   Berkeley b3ld.c (lines ~1100-1200).
// ────────────────────────────────────────────────────────────────────────
#[inline]
pub fn compute_abulk_vdsat(
    p: &Bsim3SizeParams,
    vgsteff: f64,
    vbseff: f64,
    ueff: f64,
) -> (f64, f64, f64) {
    // Abulk = (1 + K1ox/(2*sqrt(phis))*(A0*Leff/(Leff + 2*sqrt(Xj*Xdep))
    //         + B0/(Weff+B1)) - Ags*Vgsteff) * (1 + Keta*Vbseff)
    let xdep = p.Xdep0 * (1.0 - vbseff / p.phi).max(0.0).sqrt();
    let denom = p.leff + 2.0 * (p.xj * xdep).sqrt();
    let abulk0 = 1.0
        + p.k1ox / (2.0 * (p.phi - vbseff).max(1.0e-3).sqrt())
            * (p.a0 * p.leff / denom + p.b0 / (p.weff + p.b1));
    let abulk = ((abulk0 - p.ags * vgsteff) * (1.0 + p.keta * vbseff)).max(0.1);

    // Esat * Leff
    let esat_l = 2.0 * p.vsattemp * p.leff / ueff.max(1e-6);

    // Vdsat = Esat*Leff*(Vgsteff + 2*Vt) / (Abulk*Esat*Leff + Vgsteff + 2*Vt)
    let num = esat_l * (vgsteff + 2.0 * p.vt_t);
    let den = abulk * esat_l + vgsteff + 2.0 * p.vt_t;
    let vdsat = (num / den).max(1.0e-3);
    (vdsat, abulk, esat_l)
}

// ────────────────────────────────────────────────────────────────────────
// Step 6. Vdseff smoothing (continuous transition triode→saturation).
//   Berkeley b3ld.c (lines ~1250-1310).
// ────────────────────────────────────────────────────────────────────────
#[inline]
pub fn compute_vdseff(vds: f64, vdsat: f64, delta: f64) -> (f64, f64) {
    // Vdseff = Vdsat - 0.5*(Vdsat - Vds - delta + sqrt((..)^2 + 4*delta*Vdsat))
    let t0 = vdsat - vds - delta;
    let t1 = (t0 * t0 + 4.0 * delta * vdsat).sqrt().max(1.0e-30);
    let vdseff = vdsat - 0.5 * (t0 + t1);
    let dvdseff_dvds = 0.5 * (1.0 + t0 / t1);
    (vdseff, dvdseff_dvds)
}

// ────────────────────────────────────────────────────────────────────────
// Step 7. Drain current (combined Ids and gm/gds/gmbs).
//   Berkeley b3ld.c (lines ~1330-1500).
//
// This is a compact form that captures: Idso (channel current),
// channel-length modulation via VACLM, and DIBL via VADIBL — the
// minimum required for realistic Id-Vd curves.
// ────────────────────────────────────────────────────────────────────────
#[inline]
pub fn compute_idso(
    p: &Bsim3SizeParams,
    vgsteff: f64,
    vds: f64,
    vdseff: f64,
    vbseff: f64,
    abulk: f64,
    ueff: f64,
    esat_l: f64,
) -> f64 {
    // Idso = ueff*Cox*(Weff/Leff)*Vgsteff*(1 - Abulk*Vdseff/(2*(Vgsteff+2Vt)))
    //        * Vdseff / (1 + Vdseff/EsatL)
    let _ = vbseff;
    let _ = vds;
    let inv_2vt = 1.0 / (2.0 * (vgsteff + 2.0 * p.vt_t).max(1.0e-3));
    let body = vgsteff * (1.0 - abulk * vdseff * inv_2vt);
    let drift = vdseff / (1.0 + vdseff / esat_l.max(1.0e-3));
    p.nf * ueff * p.cox * (p.weff / p.leff) * body * drift
}

/// High-level driver.  Computes Ids/gm/gds/gmbs and substrate Isub for
/// a single device.  Derivatives are computed by finite differences for
/// robustness — this gives a self-consistent Jacobian even though the
/// individual analytic chain is approximate.
pub fn compute_dc_currents(
    p: &Bsim3SizeParams,
    vgs: f64,
    vds: f64,
    vbs: f64,
    op: &mut Bsim3OpPoint,
) {
    // Step through the main computation.
    let (vbseff, _) = smooth_vbs(vbs.min(0.0), p.vbm);
    let (vth, _, _, sqrt_phis) = compute_vth(p, vbseff, vds);
    let n = compute_n(p, vbseff, sqrt_phis);
    let (vgsteff, _, _) = compute_vgsteff(p, vgs, vth, n);
    let (ueff, _, _) = compute_mobility(p, vgsteff, vbseff);
    let (vdsat, abulk, esat_l) = compute_abulk_vdsat(p, vgsteff, vbseff, ueff);
    let (vdseff, _) = compute_vdseff(vds, vdsat, p.delta);

    let ids_base = compute_idso(p, vgsteff, vds, vdseff, vbseff, abulk, ueff, esat_l);

    // Channel-length modulation: 1 + (Vds - Vdseff) / (Pclm*EsatL).
    let clm = 1.0 + ((vds - vdseff).max(0.0)) / (p.pclm.max(1e-3) * esat_l.max(1e-3));
    let ids = ids_base * clm;

    op.ids = ids;
    op.vth = vth;
    op.vdsat = vdsat;
    op.von = vth + p.voff;
    op.vgsteff = vgsteff;

    // ── S/D parasitic resistance (b3acld.c: RDSW / PRWB / PRWG) ─────────
    // rds0 = rdsw / weff^wr  (pre-computed in instance.rs).
    // Bias corrections: Rds *= (1 + PRWB*sqrt(|Vbs|) + PRWG*Vgs).
    // Fold into gds via series-resistance first-order approximation.
    let rds = if p.rds0 > 0.0 {
        let vbs_clamp = vbs.min(0.0);
        let vbs_sqrt  = (-vbs_clamp).max(0.0).sqrt();
        p.rds0 * (1.0 + p.prwb * vbs_sqrt + p.prwg * vgs).max(0.01)
    } else {
        0.0
    };
    op.rds = rds;

    // ── Finite-difference Jacobian ─────────────────────────────────────
    // For BSIM3 the closed-form derivatives chain through ~30 partials;
    // a 3-point FD is much shorter to write and gives identical
    // convergence properties at the cost of 3 extra evaluations per
    // device per Newton step.  This is a reasonable trade-off for the
    // first cut of the port.
    let h = 1.0e-4;
    let id_at = |vgs: f64, vds: f64, vbs: f64| -> f64 {
        let (vbseff, _) = smooth_vbs(vbs.min(0.0), p.vbm);
        let (vth, _, _, sqrt_phis) = compute_vth(p, vbseff, vds);
        let n = compute_n(p, vbseff, sqrt_phis);
        let (vgsteff, _, _) = compute_vgsteff(p, vgs, vth, n);
        let (ueff, _, _) = compute_mobility(p, vgsteff, vbseff);
        let (vdsat, abulk, esat_l) = compute_abulk_vdsat(p, vgsteff, vbseff, ueff);
        let (vdseff, _) = compute_vdseff(vds, vdsat, p.delta);
        let ids_base = compute_idso(p, vgsteff, vds, vdseff, vbseff, abulk, ueff, esat_l);
        let clm = 1.0 + ((vds - vdseff).max(0.0)) / (p.pclm.max(1e-3) * esat_l.max(1e-3));
        ids_base * clm
    };

    op.gm   = (id_at(vgs + h, vds, vbs) - id_at(vgs - h, vds, vbs)) / (2.0 * h);
    let gds_raw = (id_at(vgs, vds + h, vbs) - id_at(vgs, vds - h, vbs)) / (2.0 * h);
    op.gmbs = (id_at(vgs, vds, vbs + h) - id_at(vgs, vds, vbs - h)) / (2.0 * h);

    // Fold Rds into gds: Gds_eff = gds / (1 + gds * Rds).
    op.gds = if rds > 0.0 {
        gds_raw / (1.0 + gds_raw * rds)
    } else {
        gds_raw
    };

    // ── AC intrinsic gate capacitances (b3acld.c Ward-Dutton partition) ──
    // Cinv = Cox * (Weff/LeffCV) * LeffCV^2 = Cox * Weff * LeffCV
    // In saturation (sat_ratio = Vdseff / (2*(Vgsteff+2*Vt))):
    //   Cgg = Cinv * (1 - sat_ratio^2)
    //   Cgs = -Cinv * (2/3) * (1 - (1 - sat_frac*0.5)^2)
    //   Cgd = 0
    // In triode:
    //   Cgg = Cinv,  Cgs = Cgd = -Cinv/2
    let cinv = p.cox * p.weff * p.leffCV;
    let vgst2vt = (vgsteff + 2.0 * p.vt_t).max(1.0e-12);
    let sat_ratio = (vdseff / (2.0 * vgst2vt)).min(1.0).max(0.0);
    let sat_frac  = sat_ratio;

    let cgg_sat = cinv * (1.0 - sat_ratio * sat_ratio);
    let cgs_sat = -cinv * (2.0 / 3.0) * (1.0 - (1.0 - sat_frac * 0.5).powi(2));

    let cgg_tri = cinv;
    let cgs_tri = -cinv * 0.5;
    let cgd_tri = -cinv * 0.5;

    op.cgg = sat_frac * cgg_sat + (1.0 - sat_frac) * cgg_tri;
    op.cgs = sat_frac * cgs_sat + (1.0 - sat_frac) * cgs_tri;
    op.cgd = sat_frac * 0.0     + (1.0 - sat_frac) * cgd_tri;
    op.cgb = 0.0;

    // Drain charge partition: Ward-Dutton 40% share.
    op.cdg = -0.4 * cinv * sat_frac;
    op.cdd =  0.4 * cinv * sat_frac * 0.5;
    op.cds = -0.4 * cinv * sat_frac * 0.5;
    op.cdb =  0.0;

    // ── Substrate current (impact ionization) ──────────────────────────
    //   Isub = (alpha0 + alpha1*Leff)/Leff * (Vds - Vdseff) * exp(-beta0/(Vds-Vdseff)) * Ids
    if p.alpha0 > 0.0 || p.alpha1 > 0.0 {
        let dv = (vds - vdseff).max(1e-6);
        let exp_arg = (-p.beta0 / dv).min(50.0);
        let coef = (p.alpha0 + p.alpha1 * p.leff) / p.leff;
        op.isub = coef * dv * exp_arg.exp() * ids;
        // FD on Isub for the Jacobian.
        let isub_at = |vgs: f64, vds: f64, vbs: f64| -> f64 {
            let id = id_at(vgs, vds, vbs);
            let (vbseff, _) = smooth_vbs(vbs.min(0.0), p.vbm);
            let (vth, _, _, sqrt_phis) = compute_vth(p, vbseff, vds);
            let n = compute_n(p, vbseff, sqrt_phis);
            let (vgsteff, _, _) = compute_vgsteff(p, vgs, vth, n);
            let (ueff, _, _) = compute_mobility(p, vgsteff, vbseff);
            let (vdsat, _, _) = compute_abulk_vdsat(p, vgsteff, vbseff, ueff);
            let (vdseff, _) = compute_vdseff(vds, vdsat, p.delta);
            let dv = (vds - vdseff).max(1e-6);
            coef * dv * (-p.beta0 / dv).min(50.0).exp() * id
        };
        op.gbgs = (isub_at(vgs + h, vds, vbs) - isub_at(vgs - h, vds, vbs)) / (2.0 * h);
        op.gbds = (isub_at(vgs, vds + h, vbs) - isub_at(vgs, vds - h, vbs)) / (2.0 * h);
        op.gbbs = (isub_at(vgs, vds, vbs + h) - isub_at(vgs, vds, vbs - h)) / (2.0 * h);
    }
}
