use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// MESFET — Curtice (1980) GaAs model.  3-terminal device.
///
/// Pin 0 = drain, Pin 1 = gate, Pin 2 = source.
///
/// DC model (N-channel):
///   Vgs = V(gate) - V(source)
///   Vds = V(drain) - V(source)
///   Vov = Vgs - Vth
///
/// Drain current (Curtice):
///   Ids = Beta * Vov² * (1 + Lambda * Vds) * tanh(Alpha * Vds)   for Vov > 0
///   Ids = 0                                                         for Vov ≤ 0
///
/// Gate Schottky diode (gate-source junction only; same model as JFET):
///   Igs = Is_gate * (exp(Vgs / Vt) - 1)
///
/// P-channel: mirror all signs (multiply Vgs, Vds, Ids by -1).
///
/// Parameters
/// ----------
/// `beta`     — transconductance coefficient (A/V²).  Default: 1e-4
/// `vto`/`vth` — threshold voltage.  Default: -0.8 V (typical GaAs depletion MESFET)
/// `alpha`    — saturation voltage parameter (1/V).   Default: 2.0
/// `lambda`   — channel-length modulation (1/V).      Default: 0.0
/// `b`        — doping profile parameter (unused in Level 1; reserved). Default: 0.0
/// `is_gate`  — gate Schottky saturation current (A). Default: 1e-14
#[derive(Debug, Clone, Copy)]
pub struct Mesfet {
    /// +1.0 for N-channel, -1.0 for P-channel.
    polarity: f64,
}

impl Mesfet {
    pub fn nmos() -> Self { Self { polarity: 1.0 } }
    pub fn pmos() -> Self { Self { polarity: -1.0 } }
}

const VT: f64 = 0.02585; // thermal voltage @ 300 K
const GDS_MIN: f64 = 1e-12;

impl DeviceModel for Mesfet {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let beta   = params.get_or("beta",    1e-4_f64);
        // Accept either "vth" or "vto" as the threshold parameter name.
        let vth    = params.get_or("vth",  params.get_or("vto", -0.8_f64));
        let alpha  = params.get_or("alpha",  2.0_f64);
        let lambda = params.get_or("lambda", 0.0_f64);
        let is_g   = params.get_or("is_gate", 1e-14_f64);

        let sign = self.polarity;

        // Flip voltages for P-channel so we can treat everything as N-channel below.
        let vgs = sign * (voltages[1] - voltages[2]);
        let vds = sign * (voltages[0] - voltages[2]);

        // Overdrive voltage.
        let vov = vgs - vth;

        // ── Curtice drain current ─────────────────────────────────────────────
        // Ids = Beta * Vov² * (1 + Lambda*Vds) * tanh(Alpha*Vds)  for Vov > 0
        //
        // Derivatives (analytical):
        //   gm  = dIds/dVgs = 2*Beta*Vov * (1+Lambda*Vds) * tanh(Alpha*Vds)
        //   gds = dIds/dVds = Beta*Vov² * [ Lambda*tanh(Alpha*Vds)
        //                                  + (1+Lambda*Vds)*Alpha*sech²(Alpha*Vds) ]
        //         + GDS_MIN

        let (ids, gm, gds) = if vov <= 0.0 {
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else {
            let alpha_vds  = alpha * vds;
            let tanh_av    = alpha_vds.tanh();
            // sech²(x) = 1 - tanh²(x)
            let sech2_av   = 1.0 - tanh_av * tanh_av;
            let clm        = 1.0 + lambda * vds;

            let ids = beta * vov * vov * clm * tanh_av + GDS_MIN * vds;
            let gm  = 2.0 * beta * vov * clm * tanh_av;
            let gds = beta * vov * vov
                    * (lambda * tanh_av + clm * alpha * sech2_av)
                    + GDS_MIN;
            (ids, gm, gds)
        };

        // ── Gate Schottky diode (gate-source) ────────────────────────────────
        // Use the physical (unsigned) gate-source voltage to avoid spurious
        // forward bias on P-channel devices.
        let vgs_phys  = voltages[1] - voltages[2];
        let vgs_clamp = vgs_phys.clamp(-40.0 * VT, 0.5);
        let exp_vgs   = (vgs_clamp / VT).exp();
        let ig        = is_g * (exp_vgs - 1.0);
        let gg        = is_g * exp_vgs / VT;

        let ids_s = sign * ids;
        let ig_s  = sign * ig;

        // ── KCL stamp ─────────────────────────────────────────────────────────
        // Drain (0):  +Ids + small gate-drain leakage (½ Ig)
        // Gate  (1):  -Ig
        // Source(2):  -(Ids + ½ Ig)
        //
        // Conductance Jacobian (N-channel convention; sign cancels for P):
        //   dId/dVd = gds,   dId/dVg = gm,   dId/dVs = -(gm+gds)
        //   dIg/dVg = gg,    dIg/dVs = -gg

        DeviceEval {
            g: smallvec![
                 ids_s + ig_s * 0.5,
                -ig_s,
                -(ids_s + ig_s * 0.5),
            ],
            q: SmallVec::new(),
            G: smallvec![
                // Drain row
                (0, 0,  gds),
                (0, 1,  gm + gg * 0.5),
                (0, 2, -(gm + gds) - gg * 0.5),
                // Gate row
                (1, 1, -gg),
                (1, 2,  gg),
                // Source row
                (2, 0, -gds),
                (2, 1, -(gm + gg * 0.5)),
                (2, 2,  gm + gds + gg * 0.5),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize { 3 }

    fn kind(&self) -> DeviceKind {
        if self.polarity > 0.0 { DeviceKind::MesfetN } else { DeviceKind::MesfetP }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn n_params() -> ParamMap {
        let mut p = ParamMap::new();
        p.set("beta",    1e-3_f64);
        p.set("vth",    -0.8_f64);
        p.set("alpha",   2.0_f64);
        p.set("lambda",  0.0_f64);
        p.set("is_gate", 1e-14_f64);
        p
    }

    fn p_params() -> ParamMap {
        // P-channel uses a "pmesfet" flag to tell the outer model, but polarity
        // is encoded in the struct.  Just reuse N params for the evaluation test.
        n_params()
    }

    /// Cutoff: Vgs < Vth → Ids ≈ 0
    #[test]
    fn nmesfet_cutoff() {
        let m = Mesfet::nmos();
        let mut p = n_params();
        p.set("vth", -0.8);
        // Vgs = -2 - 0 = -2 < Vth=-0.8 → cutoff
        let eval = m.eval(&[3.0, -2.0, 0.0], &p);
        assert!(eval.g[0].abs() < 1e-10, "cutoff Ids={}", eval.g[0]);
    }

    /// On-state: Vgs above threshold, large Vds → Ids > 0
    #[test]
    fn nmesfet_on_state() {
        let m = Mesfet::nmos();
        let p = n_params();
        // Vgs=0, Vth=-0.8, Vov=0.8, Vds=3 → should be conducting
        let eval = m.eval(&[3.0, 0.0, 0.0], &p);
        assert!(eval.g[0] > 1e-6, "on-state Ids={}", eval.g[0]);
    }

    /// KCL: sum of all terminal currents must be zero.
    #[test]
    fn nmesfet_kcl() {
        let m = Mesfet::nmos();
        let p = n_params();
        let eval = m.eval(&[3.0, 0.0, 0.0], &p);
        let sum: f64 = eval.g.iter().sum();
        assert!(sum.abs() < 1e-20, "KCL violation: {sum}");
    }

    /// Lambda > 0 → CLM: higher Vds → higher Ids in saturation.
    #[test]
    fn nmesfet_clm() {
        let m = Mesfet::nmos();
        let mut p = n_params();
        p.set("lambda", 0.05);
        let e_low  = m.eval(&[2.0, 0.0, 0.0], &p);
        let e_high = m.eval(&[5.0, 0.0, 0.0], &p);
        assert!(e_high.g[0] > e_low.g[0],
            "CLM: Ids(Vds=5)={} should exceed Ids(Vds=2)={}", e_high.g[0], e_low.g[0]);
    }

    /// Analytical Jacobian gds vs finite-difference.
    #[test]
    fn nmesfet_jacobian_gds_fd() {
        let m = Mesfet::nmos();
        let p = n_params();
        let v = [3.0_f64, 0.0, 0.0];
        let h = 1e-6;
        let e0  = m.eval(&v,                    &p);
        let e_h = m.eval(&[v[0]+h, v[1], v[2]], &p);
        let fd_gds   = (e_h.g[0] - e0.g[0]) / h;
        let anal_gds = e0.G.iter()
            .find(|&&(r,c,_)| r==0 && c==0)
            .map(|&(_,_,v)| v).unwrap_or(0.0);
        assert!(
            (fd_gds - anal_gds).abs() < 1e-5,
            "gds FD={fd_gds:.6e} anal={anal_gds:.6e}"
        );
    }

    /// Analytical Jacobian gm vs finite-difference.
    #[test]
    fn nmesfet_jacobian_gm_fd() {
        let m = Mesfet::nmos();
        let p = n_params();
        let v = [3.0_f64, 0.0, 0.0];
        let h = 1e-6;
        let e0  = m.eval(&v,                    &p);
        let e_h = m.eval(&[v[0], v[1]+h, v[2]], &p);
        let fd_gm   = (e_h.g[0] - e0.g[0]) / h;
        let anal_gm = e0.G.iter()
            .find(|&&(r,c,_)| r==0 && c==1)
            .map(|&(_,_,v)| v).unwrap_or(0.0);
        assert!(
            (fd_gm - anal_gm).abs() < 1e-5,
            "gm FD={fd_gm:.6e} anal={anal_gm:.6e}"
        );
    }

    /// P-channel: drain current should be negative for Vd < Vs.
    #[test]
    fn pmesfet_current_negative() {
        let m = Mesfet::pmos();
        let p = p_params();
        // P-ch: physical Vd=-3, Vg=0, Vs=0 → sign-flipped vds=3, vgs=0 → on
        let eval = m.eval(&[-3.0, 0.0, 0.0], &p);
        assert!(eval.g[0] < 0.0, "P-MESFET Ids should be negative: {}", eval.g[0]);
    }

    /// P-channel KCL.
    #[test]
    fn pmesfet_kcl() {
        let m = Mesfet::pmos();
        let p = p_params();
        let eval = m.eval(&[-3.0, 0.0, 0.0], &p);
        let sum: f64 = eval.g.iter().sum();
        assert!(sum.abs() < 1e-20, "P-ch KCL violation: {sum}");
    }

    /// num_terminals is 3.
    #[test]
    fn mesfet_num_terminals() {
        assert_eq!(Mesfet::nmos().num_terminals(), 3);
        assert_eq!(Mesfet::pmos().num_terminals(), 3);
    }

    /// No branch current needed (current-mode device).
    #[test]
    fn mesfet_no_branch() {
        assert!(!Mesfet::nmos().needs_branch());
        assert!(!Mesfet::pmos().needs_branch());
    }

    /// kind() returns correct DeviceKind.
    #[test]
    fn mesfet_kind() {
        assert_eq!(Mesfet::nmos().kind(), DeviceKind::MesfetN);
        assert_eq!(Mesfet::pmos().kind(), DeviceKind::MesfetP);
    }

    /// vto alias works identically to vth.
    #[test]
    fn mesfet_vto_alias() {
        let m = Mesfet::nmos();
        let p_vth = n_params(); // uses "vth"
        let mut p_vto = ParamMap::new();
        p_vto.set("beta",    1e-3_f64);
        p_vto.set("vto",    -0.8_f64); // alias
        p_vto.set("alpha",   2.0_f64);
        p_vto.set("lambda",  0.0_f64);
        p_vto.set("is_gate", 1e-14_f64);
        let e_vth = m.eval(&[3.0, 0.0, 0.0], &p_vth);
        let e_vto = m.eval(&[3.0, 0.0, 0.0], &p_vto);
        assert!((e_vth.g[0] - e_vto.g[0]).abs() < 1e-20,
            "vth={} vto={}", e_vth.g[0], e_vto.g[0]);
    }
}
