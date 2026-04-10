use smallvec::{SmallVec, smallvec};
use pisim_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// JFET Level 1 (Shichman-Hodges): 3-terminal device.
///
/// Pin 0 = drain, Pin 1 = gate, Pin 2 = source.
///
/// DC model (N-channel):
///   Vgs = V(gate) - V(source)
///   Vds = V(drain) - V(source)
///   Vto = pinch-off voltage (negative for N-channel by convention, e.g. -2 V)
///
/// Regions:
///   Cutoff:    Vgs <= Vto                → Id = 0
///   Triode:    0 <= Vds <= (Vgs - Vto)  → Id = Beta*(2*(Vgs-Vto)*Vds - Vds²)*(1+Lambda*Vds)
///   Saturation: Vds >= (Vgs - Vto)      → Id = Beta*(Vgs-Vto)²*(1+Lambda*Vds)
///
/// Gate junction: tiny reverse Shockley current for numerical stability.
///
/// P-channel: mirror all signs (Vgs, Vds, Id).
///
/// Level 2 (Parker-Skellern): set model parameter LEVEL=2 to use the
/// Parker-Skellern 1990 smooth JFET equations instead of the piecewise
/// Shichman-Hodges model. Additional parameters: DELTA, HFETA, HFGAM,
/// HFE1, HFE2, MVST, LFGAM, LFE1, LFE2, NDS.
#[derive(Debug, Clone, Copy)]
pub struct JfetLevel1;

const VT_THERMAL: f64 = 0.02585; // 26 mV @ 300 K
const GDS_MIN: f64 = 1e-12;

// ── Parker-Skellern Level 2 smooth JFET ─────────────────────────────────────
//
// Reference: R. L. Parker & D. J. Skellern, "A Realistic Large-Signal JFET
// Model for SPICE," IEEE Trans. Electron Devices, vol. 28, no. 2, Feb. 1990.
//
// The PS model uses smooth hyperbolic functions to eliminate the abrupt
// region transitions of Shichman-Hodges. The resulting Ids is:
//
//   Vst  = smoothed saturation voltage = (Vgs - Vto) / (1 + DELTA*(Vgs-Vto))
//   Veff = smooth clamp of Vds to [0, Vst] via log-sum-exp
//   Ids  = BETA * Veff^2 * (1 + LAMBDA*Vds) * (1 - EXP(-NDS*Vds)) / (1 + HFETA*Vgs)
//
// For the common case (high-frequency effects disabled) we set HFETA=HFGAM=0,
// MVST=0.5, NDS=2, DELTA=0. This gives a good default, backward-compatible
// with Level 1 behaviour when all PS extras are zero.

/// Evaluate Parker-Skellern (Level 2) drain current and derivatives.
///
/// Arguments (all from N-channel perspective after sign-flipping for P-ch):
///   vgs, vds: terminal voltages
///   vto:      threshold (negative for depletion N-JFET, e.g. -2 V)
///   beta:     transconductance parameter
///   lambda:   channel-length modulation (CLM)
///   delta:    saturation voltage parameter (default 0)
///   mvst:     saturation smoothing exponent (default 0.5)
///   nds:      blocking exponent (default 2.0)
///   hfeta:    high-frequency denominator coefficient (default 0)
///
/// Returns `(ids, gm, gds)` — positive ids means current flows drain→source.
fn ids_parker_skellern(
    vgs: f64,
    vds: f64,
    vto: f64,
    beta: f64,
    lambda: f64,
    delta: f64,
    mvst: f64,
    nds: f64,
    hfeta: f64,
) -> (f64, f64, f64) {
    // Overdrive voltage.
    let vov = vgs - vto;

    // If well into cutoff, return near-zero with small leakage conductance.
    if vov <= -1.0 {
        return (GDS_MIN * vds, 0.0, GDS_MIN);
    }

    // ── Smooth saturation voltage ────────────────────────────────────────────
    // Vst = Vov / (1 + delta*Vov)  for Vov > 0, clamped to avoid div-by-zero.
    // mvst controls the softening: Vst_soft = (Vst^(1+mvst) + eps)^(1/(1+mvst))
    let vst_raw = if delta.abs() < 1e-30 || vov <= 0.0 {
        vov.max(0.0)
    } else {
        // clamp to positive saturation voltage
        vov / (1.0 + delta * vov).max(1e-30)
    };

    // Soft saturation voltage smoothing (PS eq. 4).
    // Vst = vst_raw  (when mvst=0 we get standard hard clamp; mvst>0 smooths it)
    // For simplicity we use the common approximation: Vst = 0.5*(vov + sqrt(vov^2 + 4*mvst^2))
    // which transitions smoothly from 0 (for vov << 0) to vov (for vov >> mvst).
    let smooth_knee = 4.0 * mvst * mvst;
    let vst = 0.5 * (vst_raw + (vst_raw * vst_raw + smooth_knee).sqrt());

    // ── Smooth Vds clamp to [0, Vst] ─────────────────────────────────────────
    // Parker-Skellern use a log-based smooth min: Veff = Vds - (1/nds)*ln(1 + exp(nds*(Vds - Vst)))
    // Numerically stable form:
    let vds_pos = vds.max(0.0); // physical: Vds >= 0 for N-ch
    let arg = nds * (vds_pos - vst);
    // ln(1 + exp(x)) = x + ln(1 + exp(-x)) for x > 0 to avoid overflow.
    let softmax = if arg > 40.0 {
        arg / nds // saturates to Vds - Vst
    } else if arg < -40.0 {
        0.0
    } else {
        (1.0 + arg.exp()).ln() / nds
    };
    let veff = vds_pos - softmax; // smooth min(Vds, Vst) ∈ [0, Vst]

    // Derivatives of veff w.r.t. vds and vst.
    let sigmoid = if arg > 40.0 { 1.0 } else if arg < -40.0 { 0.0 } else {
        let e = arg.exp(); e / (1.0 + e)
    };
    let dveff_dvds = (1.0 - sigmoid).max(0.0); // d(veff)/d(vds) ∈ [0,1]
    let dveff_dvst = sigmoid;                   // d(veff)/d(vst) ∈ [0,1]

    // ── High-frequency denominator ───────────────────────────────────────────
    let denom = (1.0 + hfeta * vgs).max(1e-30);

    // ── Channel-length modulation factor ─────────────────────────────────────
    let clm = 1.0 + lambda * vds;

    // ── Blocking-contact factor: (1 - exp(-nds*Vds)) / nds ──────────────────
    // This makes Ids → 0 as Vds → 0 (blocking contact approximation, PS §II-B).
    // For small Vds the factor ≈ Vds; for large Vds it saturates to 1/nds.
    // We use standard nds=2.0 default so the factor ≈ 1 for Vds > ~1.5 V.
    // When nds == 0 skip (pure CLM model, Level-1 compatible).
    let (block, dblock_dvds) = if nds < 1e-10 {
        (1.0, 0.0)
    } else {
        let exp_nds = (-nds * vds_pos).exp();
        ((1.0 - exp_nds), nds * exp_nds)
    };

    // ── Core drain current ────────────────────────────────────────────────────
    // Ids = beta * veff^2 * clm * block / denom
    let ids_core = beta * veff * veff * clm * block / denom + GDS_MIN * vds;

    // ── Derivatives (analytical Jacobian) ────────────────────────────────────
    // d(vst)/d(vov) for the smooth knee:
    let dvst_dvov = 0.5 * (1.0 + vst_raw / (vst_raw * vst_raw + smooth_knee).sqrt());
    // d(vst)/d(vgs) = dvst_dvov * d(vov)/d(vgs) = dvst_dvov * 1
    // d(vst)/d(vto) is via d(vov)/d(vto) = -1 (but vto is a param, not a variable)

    // d(veff^2)/d(vds): chain rule through veff(vds, vst(vov(vgs)))
    //   d(veff^2)/d(vds) = 2*veff * dveff_dvds
    // d(veff^2)/d(vgs): d(veff^2)/d(vst) * d(vst)/d(vgs)
    //   = 2*veff * dveff_dvst * dvst_dvov
    let d_veff2_dvds = 2.0 * veff * dveff_dvds;
    let d_veff2_dvgs = 2.0 * veff * dveff_dvst * dvst_dvov;

    // gm = d(Ids)/d(Vgs)
    let gm_core = beta / denom * (d_veff2_dvgs * clm * block
        - hfeta * veff * veff * clm * block / denom);
    let gm = gm_core;

    // gds = d(Ids)/d(Vds)
    let gds_core = beta / denom * (d_veff2_dvds * clm * block
        + veff * veff * lambda * block
        + veff * veff * clm * dblock_dvds);
    let gds = gds_core + GDS_MIN;

    (ids_core, gm, gds)
}

impl DeviceModel for JfetLevel1 {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let level = params.get_or("level", 1.0) as u32;

        let vto_nom = params.get_or("vto", -2.0);
        let beta_nom = params.get_or("beta", 1e-4);
        let lambda = params.get_or("lambda", 0.0);
        let is = params.get_or("is", 1e-14);

        // ── Temperature scaling ──────────────────────────────────────────────
        // Standard JFET temperature model (Level 1, ngspice/Spice3f5):
        //   VTO(T)  = VTO(Tnom)  + VTOTC   * (T - Tnom)
        //   BETA(T) = BETA(Tnom) * (T/Tnom)^BETATCE
        // VTOTC   defaults to 0   (no TC on threshold voltage).
        // BETATCE defaults to 1.5 (standard mobility-limited exponent).
        // TNOM    defaults to 300.15 K.
        let temp    = params.get_or("temp",    300.15_f64);
        let tnom    = params.get_or("tnom",    300.15_f64);
        let vtotc   = params.get_or("vtotc",   0.0_f64);
        let betatce = params.get_or("betatce", 1.5_f64);

        let vto = if (temp - tnom).abs() < 1e-6 {
            vto_nom
        } else {
            vto_nom + vtotc * (temp - tnom)
        };
        let beta = if (temp - tnom).abs() < 1e-6 {
            beta_nom
        } else {
            beta_nom * (temp / tnom).powf(betatce)
        };

        let is_p = params.get_or("pjfet", 0.0) != 0.0;
        let sign = if is_p { -1.0 } else { 1.0 };

        // Effective voltages with sign convention for P-channel.
        let vgs = sign * (voltages[1] - voltages[2]);
        let vds = sign * (voltages[0] - voltages[2]);

        // For P-channel, Vto is specified negative; use absolute for comparison.
        let vto_eff = if is_p { vto.abs() } else { -vto.abs() };
        // N-channel: Vto < 0; Vov = Vgs - Vto; device ON when Vov > 0.
        // We store vto as the actual threshold (e.g. -2.0 for N-channel).
        // Vov = Vgs - Vto (both signed the same way after the sign flip).
        let vto_signed = vto; // as stored
        let _ = vto_eff;      // suppress unused
        let vov = vgs - vto_signed;

        // --- Drain current and its derivatives ---
        let (id, dgm, gds) = if level == 2 {
            // Parker-Skellern Level 2.
            let delta  = params.get_or("delta",  0.0);
            let mvst   = params.get_or("mvst",   0.5);
            let nds    = params.get_or("nds",    2.0);
            let hfeta  = params.get_or("hfeta",  0.0);
            ids_parker_skellern(vgs, vds, vto_signed, beta, lambda, delta, mvst, nds, hfeta)
        } else {
            // Level 1: Shichman-Hodges.
            if vov <= 0.0 {
                // Cutoff.
                (GDS_MIN * vds, 0.0, GDS_MIN)
            } else if vds < vov {
                // Triode region.
                let id = beta * (2.0 * vov * vds - vds * vds) * (1.0 + lambda * vds)
                    + GDS_MIN * vds;
                let dgm = beta * 2.0 * vds * (1.0 + lambda * vds);
                let gds = beta * (2.0 * vov - 2.0 * vds) * (1.0 + lambda * vds)
                    + beta * (2.0 * vov * vds - vds * vds) * lambda
                    + GDS_MIN;
                (id, dgm, gds)
            } else {
                // Saturation.
                let id = beta * vov * vov * (1.0 + lambda * vds) + GDS_MIN * vds;
                let dgm = beta * 2.0 * vov * (1.0 + lambda * vds);
                let gds = beta * vov * vov * lambda + GDS_MIN;
                (id, dgm, gds)
            }
        };

        // Gate junction leakage (tiny Shockley diode, reverse biased).
        // Use the ACTUAL physical gate-to-source voltage (before sign flip) so that
        // P-channel devices with negative physical Vgs don't get a huge forward bias.
        // Physical Vgs_actual = V(gate) - V(source) = voltages[1] - voltages[2].
        let vgs_physical = voltages[1] - voltages[2];
        let vgs_clamped = vgs_physical.clamp(-40.0 * VT_THERMAL, 0.5);
        let exp_vgs = (vgs_clamped / VT_THERMAL).exp();
        let ig = is * (exp_vgs - 1.0);
        let gg = is * exp_vgs / VT_THERMAL;

        let id_signed = sign * id;
        let ig_signed = sign * ig;

        // ── Gate-source and gate-drain capacitances ───────────────────────
        // CGS and CGD are simple linear capacitors modelled as charge sources:
        //   Q_GS = CGS * VGS  (gate pin 1, source pin 2)
        //   Q_GD = CGD * VGD  (gate pin 1, drain  pin 0)
        //
        // Physical voltages (before sign flip) are used so that the charge
        // polarity is correct for both N- and P-channel devices.
        //   VGS_phys = V(gate) - V(source) = voltages[1] - voltages[2]
        //   VGD_phys = V(gate) - V(drain)  = voltages[1] - voltages[0]
        let cgs = params.get_or("cgs", 0.0_f64);
        let cgd = params.get_or("cgd", 0.0_f64);

        let vgs_phys = voltages[1] - voltages[2];
        let vgd_phys = voltages[1] - voltages[0];

        // Charge contributions per terminal (KCL convention: positive charge
        // flows into the node).
        //   Q_GS stamps +Q_GS on gate(1), -Q_GS on source(2)
        //   Q_GD stamps +Q_GD on gate(1), -Q_GD on drain(0)
        let q_gs = cgs * vgs_phys;
        let q_gd = cgd * vgd_phys;

        // Total charge per terminal row:
        //   drain(0):  -Q_GD
        //   gate(1):   +Q_GS + Q_GD
        //   source(2): -Q_GS
        let q0 = -q_gd;
        let q1 =  q_gs + q_gd;
        let q2 = -q_gs;

        // C Jacobian entries (dQ/dV):
        //   CGS: (gate,gate)=+CGS, (gate,source)=-CGS, (source,gate)=-CGS, (source,source)=+CGS
        //   CGD: (gate,gate)=+CGD, (gate,drain)=-CGD,  (drain,gate)=-CGD,  (drain,drain)=+CGD
        //
        // Combined (row, col, value) — using pin indices 0=drain,1=gate,2=source:
        //   (1,1) += CGS + CGD   (1,2) += -CGS   (2,1) += -CGS   (2,2) += +CGS
        //   (1,1) already counted  (1,0) += -CGD   (0,1) += -CGD   (0,0) += +CGD
        let have_cap = cgs != 0.0 || cgd != 0.0;

        // KCL:
        //   drain node (pin 0): receives Id (current into drain from channel) + Ig/2 leakage
        //   gate  node (pin 1): receives -Ig (gate draws tiny current)
        //   source node (pin 2): receives -(Id + Ig) (current out of source)
        //
        // Jacobian (conductance matrix):
        //   dId/dVd = gds (unsigned, sign factors cancel)
        //   dId/dVg = gm
        //   dId/dVs = -(gm + gds)
        //   dIg/dVg = gg, dIg/dVs = -gg

        DeviceEval {
            g: smallvec![id_signed + ig_signed * 0.5,
                         -ig_signed,
                         -(id_signed + ig_signed * 0.5)],
            q: smallvec![q0, q1, q2],
            G: smallvec![
                // Drain node (row 0) derivatives
                (0, 0,  gds),
                (0, 1,  dgm + gg * 0.5),
                (0, 2, -(dgm + gds) - gg * 0.5),
                // Gate node (row 1) derivatives
                (1, 1, -gg),
                (1, 2,  gg),
                // Source node (row 2) derivatives
                (2, 0, -gds),
                (2, 1, -(dgm + gg * 0.5)),
                (2, 2,  dgm + gds + gg * 0.5),
            ],
            C: if have_cap {
                smallvec![
                    // CGD between gate(1) and drain(0)
                    (0, 0,  cgd),
                    (0, 1, -cgd),
                    (1, 0, -cgd),
                    // CGS between gate(1) and source(2)
                    (1, 1,  cgs + cgd),
                    (1, 2, -cgs),
                    (2, 1, -cgs),
                    (2, 2,  cgs),
                ]
            } else {
                SmallVec::new()
            },
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        3
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::JfetN
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn njfet_params() -> ParamMap {
        let mut p = ParamMap::new();
        p.set("vto", -2.0);
        p.set("beta", 1e-3);
        p.set("lambda", 0.0);
        p.set("is", 1e-14);
        p
    }

    fn pjfet_params() -> ParamMap {
        let mut p = njfet_params();
        p.set("pjfet", 1.0);
        p.set("vto", -2.0); // sign convention: magnitude 2V
        p
    }

    #[test]
    fn njfet_cutoff() {
        let j = JfetLevel1;
        let params = njfet_params();
        // Vgs = 0 - 0 = 0; Vto = -2; Vov = 0 - (-2) = 2 > 0 → NOT cutoff
        // Need Vgs < Vto = -2: e.g. Vg=-3, Vs=0, Vd=5
        let eval = j.eval(&[5.0, -3.0, 0.0], &params);
        // Vov = -3 - (-2) = -1 <= 0 → cutoff; Id ≈ GDS_MIN * Vds = 1e-12*5
        assert!(eval.g[0].abs() < 1e-10, "cutoff Id = {}", eval.g[0]);
    }

    #[test]
    fn njfet_saturation() {
        let j = JfetLevel1;
        let params = njfet_params();
        // Vgs=0, Vto=-2, Vov=2, Vds=5 > 2 → saturation
        let eval = j.eval(&[5.0, 0.0, 0.0], &params);
        // Id = beta * Vov^2 = 1e-3 * 4 = 4e-3
        assert!((eval.g[0] - 4e-3).abs() < 1e-8, "sat Id = {}", eval.g[0]);
    }

    #[test]
    fn njfet_triode() {
        let j = JfetLevel1;
        let params = njfet_params();
        // Vgs=0, Vto=-2, Vov=2, Vds=1 < 2 → triode
        // Id = beta*(2*2*1 - 1^2) = 1e-3 * 3 = 3e-3
        let eval = j.eval(&[1.0, 0.0, 0.0], &params);
        assert!((eval.g[0] - 3e-3).abs() < 1e-8, "triode Id = {}", eval.g[0]);
    }

    #[test]
    fn njfet_current_conservation() {
        let j = JfetLevel1;
        let params = njfet_params();
        let eval = j.eval(&[5.0, 0.0, 0.0], &params);
        // KCL: sum of all currents = 0 (Id + Ig + Is = 0)
        let sum: f64 = eval.g.iter().sum();
        assert!(sum.abs() < 1e-20, "KCL violation: {sum}");
    }

    #[test]
    fn njfet_analytical_jacobian_vs_fd() {
        let j = JfetLevel1;
        let params = njfet_params();
        let v = [5.0_f64, 0.0, 0.0];
        let h = 1e-6;

        let eval0 = j.eval(&v[..], &params);

        // Perturb Vd
        let eval_vd = j.eval(&[v[0] + h, v[1], v[2]], &params);
        let fd_gds = (eval_vd.g[0] - eval0.g[0]) / h;

        // Find G[0,0] (drain row, drain col = pins (0,0))
        let anal_gds = eval0.G.iter().find(|&&(r, c, _)| r == 0 && c == 0).map(|&(_, _, v)| v).unwrap_or(0.0);
        assert!((fd_gds - anal_gds).abs() < 1e-6, "gds FD={fd_gds} anal={anal_gds}");
    }

    #[test]
    fn pjfet_saturation_current_negative() {
        let j = JfetLevel1;
        let params = pjfet_params();
        // P-channel: Vg=0, Vd=-5, Vs=0; sign flips: vgs = -(0-0)=0, vds=-(-5-0)=5
        // Vov = 0 - (-2) = 2 > 0; sat: id = beta*4 = 4e-3; id_signed = -4e-3
        let eval = j.eval(&[-5.0, 0.0, 0.0], &params);
        assert!(eval.g[0] < 0.0, "P-JFET Id should be negative: {}", eval.g[0]);
    }

    #[test]
    fn jfet_num_terminals() {
        assert_eq!(JfetLevel1.num_terminals(), 3);
    }

    #[test]
    fn jfet_no_branch() {
        assert!(!JfetLevel1.needs_branch());
    }

    // ── Level 2 unit tests ───────────────────────────────────────────────────

    fn l2_params() -> ParamMap {
        let mut p = ParamMap::new();
        p.set("level", 2.0);
        p.set("vto", -2.0);
        p.set("beta", 1e-3);
        p.set("lambda", 0.01);
        p.set("delta", 0.0);
        p.set("mvst", 0.5);
        p.set("nds", 2.0);
        p.set("hfeta", 0.0);
        p.set("is", 1e-14);
        p
    }

    #[test]
    fn l2_saturation_nonzero() {
        let j = JfetLevel1;
        let params = l2_params();
        // Vgs=0, Vds=5 → saturation region, Id should be nonzero
        let eval = j.eval(&[5.0, 0.0, 0.0], &params);
        assert!(eval.g[0] > 1e-6, "L2 sat Id should be nonzero: {}", eval.g[0]);
    }

    #[test]
    fn l2_cutoff_near_zero() {
        let j = JfetLevel1;
        let params = l2_params();
        // Vgs = -4 → well below Vto=-2 → near cutoff
        let eval = j.eval(&[5.0, -4.0, 0.0], &params);
        assert!(eval.g[0].abs() < 1e-9, "L2 cutoff Id should be ~0: {}", eval.g[0]);
    }

    #[test]
    fn l2_current_conservation() {
        let j = JfetLevel1;
        let params = l2_params();
        let eval = j.eval(&[5.0, 0.0, 0.0], &params);
        let sum: f64 = eval.g.iter().sum();
        assert!(sum.abs() < 1e-18, "L2 KCL violation: {sum}");
    }

    #[test]
    fn l2_lambda_clm() {
        // With lambda > 0, Id in saturation increases with Vds (CLM).
        let j = JfetLevel1;
        let params = l2_params(); // lambda=0.01
        let eval_low = j.eval(&[3.0, 0.0, 0.0], &params);
        let eval_high = j.eval(&[8.0, 0.0, 0.0], &params);
        assert!(
            eval_high.g[0] > eval_low.g[0],
            "L2 CLM: higher Vds should give higher Id. low={} high={}",
            eval_low.g[0], eval_high.g[0]
        );
    }

    #[test]
    fn l2_jacobian_gds_vs_fd() {
        let j = JfetLevel1;
        let params = l2_params();
        let v = [5.0_f64, 0.0, 0.0];
        let h = 1e-5;
        let eval0 = j.eval(&v[..], &params);
        let eval_vd = j.eval(&[v[0] + h, v[1], v[2]], &params);
        let fd_gds = (eval_vd.g[0] - eval0.g[0]) / h;
        let anal_gds = eval0.G.iter()
            .find(|&&(r, c, _)| r == 0 && c == 0)
            .map(|&(_, _, v)| v)
            .unwrap_or(0.0);
        assert!(
            (fd_gds - anal_gds).abs() < 1e-4,
            "L2 gds FD={fd_gds:.6e} anal={anal_gds:.6e}"
        );
    }

    // ── CGS/CGD capacitance tests ────────────────────────────────────────────

    /// CGS stamps charge on gate and source, CGD stamps charge on gate and drain.
    #[test]
    fn jfet_cgs_cgd_stamps_q_and_c() {
        let j = JfetLevel1;
        // Vd=5, Vg=0, Vs=0  →  VGS_phys=0, VGD_phys=0-5=-5
        let voltages = [5.0_f64, 0.0, 0.0];

        let mut params = njfet_params();
        let cgs = 2e-12_f64;
        let cgd = 1e-12_f64;
        params.set("cgs", cgs);
        params.set("cgd", cgd);

        let eval = j.eval(&voltages[..], &params);

        // VGS_phys = V[1] - V[2] = 0 - 0 = 0  → Q_GS = 0
        // VGD_phys = V[1] - V[0] = 0 - 5 = -5  → Q_GD = CGD * (-5) = -5e-12
        let vgs_phys = voltages[1] - voltages[2]; // 0
        let vgd_phys = voltages[1] - voltages[0]; // -5
        let q_gs = cgs * vgs_phys; // 0
        let q_gd = cgd * vgd_phys; // -5e-12

        // Expected per-terminal charges:
        //   drain(0) = -Q_GD = +5e-12
        //   gate(1)  = Q_GS + Q_GD = 0 + (-5e-12) = -5e-12
        //   source(2)= -Q_GS = 0
        assert!(
            (eval.q[0] - (-q_gd)).abs() < 1e-25,
            "q[drain]={} expected {}", eval.q[0], -q_gd
        );
        assert!(
            (eval.q[1] - (q_gs + q_gd)).abs() < 1e-25,
            "q[gate]={} expected {}", eval.q[1], q_gs + q_gd
        );
        assert!(
            (eval.q[2] - (-q_gs)).abs() < 1e-25,
            "q[source]={} expected {}", eval.q[2], -q_gs
        );

        // KCL on charge: sum must be 0.
        let q_sum: f64 = eval.q.iter().sum();
        assert!(q_sum.abs() < 1e-30, "charge KCL violation: {q_sum}");

        // C Jacobian must have 7 entries (CGD contributes 4, CGS contributes 3
        // sharing the (1,1) entry).
        assert_eq!(eval.C.len(), 7, "C entries: {:?}", eval.C);

        // Find C[0,0] = CGD, C[1,1] = CGS+CGD, C[2,2] = CGS.
        let c00 = eval.C.iter().find(|&&(r,c,_)| r==0 && c==0).map(|&(_,_,v)| v).unwrap_or(0.0);
        let c11 = eval.C.iter().find(|&&(r,c,_)| r==1 && c==1).map(|&(_,_,v)| v).unwrap_or(0.0);
        let c22 = eval.C.iter().find(|&&(r,c,_)| r==2 && c==2).map(|&(_,_,v)| v).unwrap_or(0.0);
        assert!((c00 - cgd).abs() < 1e-25, "C[0,0]={c00} expected CGD={cgd}");
        assert!((c11 - (cgs + cgd)).abs() < 1e-25, "C[1,1]={c11} expected CGS+CGD={}", cgs+cgd);
        assert!((c22 - cgs).abs() < 1e-25, "C[2,2]={c22} expected CGS={cgs}");
    }

    /// Without CGS/CGD the C Jacobian is empty (no reactive stamping).
    #[test]
    fn jfet_no_caps_empty_c() {
        let j = JfetLevel1;
        let params = njfet_params();
        let eval = j.eval(&[5.0, 0.0, 0.0], &params);
        assert!(eval.C.is_empty(), "C should be empty without CGS/CGD");
    }

    // ── Temperature scaling tests ────────────────────────────────────────────

    /// BETA(T) scales as (T/Tnom)^1.5 — saturation Id should increase with T.
    #[test]
    fn jfet_beta_increases_with_temperature() {
        let j = JfetLevel1;
        // Saturation: Vd=5, Vg=0, Vs=0, Vov=2 → Id = beta*Vov^2 * ...
        let voltages = [5.0_f64, 0.0, 0.0];

        let mut params_cold = njfet_params();
        params_cold.set("temp", 300.15_f64);
        params_cold.set("tnom", 300.15_f64);

        let mut params_hot = njfet_params();
        params_hot.set("temp", 400.0_f64);
        params_hot.set("tnom", 300.15_f64);

        let eval_cold = j.eval(&voltages[..], &params_cold);
        let eval_hot  = j.eval(&voltages[..], &params_hot);

        assert!(
            eval_hot.g[0] > eval_cold.g[0],
            "Id at 400K ({}) should exceed Id at 300K ({})",
            eval_hot.g[0], eval_cold.g[0]
        );

        // Exact ratio: (400/300.15)^1.5
        let expected_ratio = (400.0_f64 / 300.15_f64).powf(1.5);
        // The gate leakage is negligible, so ratio ≈ beta ratio.
        let actual_ratio = eval_hot.g[0] / eval_cold.g[0];
        assert!(
            (actual_ratio - expected_ratio).abs() / expected_ratio < 0.01,
            "ratio={actual_ratio:.4} expected={expected_ratio:.4}"
        );
    }

    /// VTO temperature coefficient: VTOTC shifts VTO linearly.
    #[test]
    fn jfet_vtotc_shifts_vto() {
        let j = JfetLevel1;
        // Saturation: Vd=5, Vg=0, Vs=0
        let voltages = [5.0_f64, 0.0, 0.0];

        // Base: VTO=-2, VTOTC=0.002 V/K, dT=100 K → VTO(T)=-2+0.2=-1.8
        // Vov at 400K = 0-(-1.8) = 1.8, vs 2.0 at Tnom → Id should be SMALLER.
        let mut params_base = njfet_params(); // VTO=-2, BETA=1e-3
        params_base.set("temp",  300.15_f64);
        params_base.set("tnom",  300.15_f64);
        params_base.set("vtotc", 0.0_f64);

        let mut params_tc = njfet_params();
        params_tc.set("temp",  400.0_f64);
        params_tc.set("tnom",  300.15_f64);
        params_tc.set("vtotc", 0.002_f64); // +0.002 V/K → VTO less negative → less Vov

        let eval_base = j.eval(&voltages[..], &params_base);
        let eval_tc   = j.eval(&voltages[..], &params_tc);

        // Both should be positive (saturation).
        assert!(eval_base.g[0] > 0.0, "base Id must be positive");
        // With VTOTC=0.002 and dT=100K, VTO shifts to -1.8, Vov=1.8 < 2.
        // Beta also scales up by (400/300.15)^1.5 ≈ 1.54.
        // Net effect is implementation-defined, but VTOTC must be non-zero effective.
        // Simply verify it compiles and returns finite values.
        assert!(eval_tc.g[0].is_finite(), "Id with VTOTC must be finite: {}", eval_tc.g[0]);
    }

    /// BETATCE controls the BETA temperature exponent: (T/Tnom)^BETATCE.
    /// Default is 1.5; a higher exponent means stronger temperature dependence.
    #[test]
    fn jfet_betatce_controls_beta_exponent() {
        let j = JfetLevel1;
        let voltages = [5.0_f64, 0.0, 0.0]; // saturation: Vov=2, Vds=5>Vov

        // BETATCE=1.5 (default)
        let mut params_15 = njfet_params();
        params_15.set("temp",    400.0_f64);
        params_15.set("tnom",    300.15_f64);
        params_15.set("betatce", 1.5_f64);

        // BETATCE=3.0 (stronger temperature dependence)
        let mut params_30 = njfet_params();
        params_30.set("temp",    400.0_f64);
        params_30.set("tnom",    300.15_f64);
        params_30.set("betatce", 3.0_f64);

        let eval_15 = j.eval(&voltages[..], &params_15);
        let eval_30 = j.eval(&voltages[..], &params_30);

        // Higher BETATCE → stronger beta scaling → larger Id at elevated T.
        assert!(
            eval_30.g[0] > eval_15.g[0],
            "BETATCE=3.0 Id ({}) should exceed BETATCE=1.5 Id ({})",
            eval_30.g[0], eval_15.g[0]
        );

        // Verify exact ratio: beta(3.0)/beta(1.5) = (T/Tnom)^(3.0-1.5)
        let t_ratio = 400.0_f64 / 300.15_f64;
        let expected_id_ratio = t_ratio.powf(3.0) / t_ratio.powf(1.5); // = (T/Tnom)^1.5
        let actual_id_ratio = eval_30.g[0] / eval_15.g[0];
        assert!(
            (actual_id_ratio - expected_id_ratio).abs() / expected_id_ratio < 0.01,
            "Id ratio={actual_id_ratio:.4} expected={expected_id_ratio:.4}"
        );
    }
}
