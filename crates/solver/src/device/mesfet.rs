use incspice_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::device::eval::{DeviceEval, DeviceModel};

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
    pub fn nmos() -> Self {
        Self { polarity: 1.0 }
    }
    pub fn pmos() -> Self {
        Self { polarity: -1.0 }
    }
}

const VT: f64 = 0.02585; // thermal voltage @ 300 K
const GDS_MIN: f64 = 1e-12;

impl DeviceModel for Mesfet {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let beta = params.get_or("beta", 1e-4_f64);
        // Accept either "vth" or "vto" as the threshold parameter name.
        let vth = params.get_or("vth", params.get_or("vto", -0.8_f64));
        let alpha = params.get_or("alpha", 2.0_f64);
        let lambda = params.get_or("lambda", 0.0_f64);
        let is_g = params.get_or("is_gate", 1e-14_f64);

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
            let alpha_vds = alpha * vds;
            let tanh_av = alpha_vds.tanh();
            // sech²(x) = 1 - tanh²(x)
            let sech2_av = 1.0 - tanh_av * tanh_av;
            let clm = 1.0 + lambda * vds;

            let ids = beta * vov * vov * clm * tanh_av + GDS_MIN * vds;
            let gm = 2.0 * beta * vov * clm * tanh_av;
            let gds = beta * vov * vov * (lambda * tanh_av + clm * alpha * sech2_av) + GDS_MIN;
            (ids, gm, gds)
        };

        // ── Gate Schottky diodes (gate-source and gate-drain) ────────────────
        // Use physical (unsigned) voltages to avoid spurious forward bias on
        // P-channel devices.
        //   Vgs_phys = V(gate) - V(source) = voltages[1] - voltages[2]
        //   Vgd_phys = V(gate) - V(drain)  = voltages[1] - voltages[0]
        let vgs_phys = voltages[1] - voltages[2];
        let vgd_phys = voltages[1] - voltages[0];

        let vgs_clamp = vgs_phys.clamp(-40.0 * VT, 0.5);
        let exp_vgs = (vgs_clamp / VT).exp();
        let igs = is_g * (exp_vgs - 1.0);
        let ggs = is_g * exp_vgs / VT;

        let vgd_clamp = vgd_phys.clamp(-40.0 * VT, 0.5);
        let exp_vgd = (vgd_clamp / VT).exp();
        let igd = is_g * (exp_vgd - 1.0);
        let ggd = is_g * exp_vgd / VT;

        let ids_s = sign * ids;

        // ── KCL stamp (two-diode gate leakage model) ──────────────────────────
        // Igs flows gate→source: gate loses Igs, source gains Igs.
        // Igd flows gate→drain:  gate loses Igd, drain  gains Igd.
        //
        // MNA convention: g[node] = net current LEAVING that node.
        //   drain  (0): id leaves; igd enters from gate → ids_s - sign*igd
        //   gate   (1): igs and igd both leave           → sign*(igs + igd)
        //   source (2): id and igs both enter            → -(ids_s + sign*igs)
        //
        // Jacobian (same derivation as jfet.rs — physical diode voltages used):
        //   d(-sign*igd)/dV[0] = sign*ggd,  d(-sign*igd)/dV[1] = -sign*ggd
        //   d(sign*igs)/dV[1]  = sign*ggs,  d(sign*igs)/dV[2]  = -sign*ggs
        //   d(sign*igd)/dV[1]  = sign*ggd,  d(sign*igd)/dV[0]  = -sign*ggd
        //   d(-sign*igs)/dV[1] = -sign*ggs, d(-sign*igs)/dV[2] = sign*ggs

        // ── Gate-source and gate-drain capacitances ───────────────────────
        // CGS and CGD are linear capacitors modelled as charge sources,
        // identical to the JFET gate capacitance model.
        //   Q_GS = CGS * VGS_phys  (gate pin 1, source pin 2)
        //   Q_GD = CGD * VGD_phys  (gate pin 1, drain  pin 0)
        //
        // Physical (unsigned) voltages are used so that charge polarity
        // is correct for both N- and P-channel devices.
        let cgs = params.get_or("cgs", 0.0_f64);
        let cgd = params.get_or("cgd", 0.0_f64);

        let q_gs = cgs * vgs_phys;
        let q_gd = cgd * vgd_phys;

        // Total charge per terminal row:
        //   drain(0):  -Q_GD
        //   gate(1):   +Q_GS + Q_GD
        //   source(2): -Q_GS
        let q0 = -q_gd;
        let q1 = q_gs + q_gd;
        let q2 = -q_gs;

        let have_cap = cgs != 0.0 || cgd != 0.0;

        DeviceEval {
            g: smallvec![
                ids_s - sign * igd,
                sign * (igs + igd),
                -(ids_s + sign * igs),
            ],
            q: smallvec![q0, q1, q2],
            G: smallvec![
                // Drain row
                (0, 0, gds + sign * ggd),
                (0, 1, gm - sign * ggd),
                (0, 2, -(gm + gds)),
                // Gate row
                (1, 0, -sign * ggd),
                (1, 1, sign * (ggs + ggd)),
                (1, 2, -sign * ggs),
                // Source row
                (2, 0, -gds),
                (2, 1, -(gm + sign * ggs)),
                (2, 2, gm + gds + sign * ggs),
            ],
            C: if have_cap {
                // C Jacobian entries (dQ/dV):
                //   CGD: (0,0)=+CGD, (0,1)=-CGD, (1,0)=-CGD
                //   CGS: (1,1)=+CGS+CGD, (1,2)=-CGS, (2,1)=-CGS, (2,2)=+CGS
                smallvec![
                    // CGD between gate(1) and drain(0)
                    (0, 0, cgd),
                    (0, 1, -cgd),
                    (1, 0, -cgd),
                    // CGS between gate(1) and source(2)
                    (1, 1, cgs + cgd),
                    (1, 2, -cgs),
                    (2, 1, -cgs),
                    (2, 2, cgs),
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
        if self.polarity > 0.0 {
            DeviceKind::MesfetN
        } else {
            DeviceKind::MesfetP
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn n_params() -> ParamMap {
        let mut p = ParamMap::new();
        p.set("beta", 1e-3_f64);
        p.set("vth", -0.8_f64);
        p.set("alpha", 2.0_f64);
        p.set("lambda", 0.0_f64);
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
        let e_low = m.eval(&[2.0, 0.0, 0.0], &p);
        let e_high = m.eval(&[5.0, 0.0, 0.0], &p);
        assert!(
            e_high.g[0] > e_low.g[0],
            "CLM: Ids(Vds=5)={} should exceed Ids(Vds=2)={}",
            e_high.g[0],
            e_low.g[0]
        );
    }

    /// Analytical Jacobian gds vs finite-difference.
    #[test]
    fn nmesfet_jacobian_gds_fd() {
        let m = Mesfet::nmos();
        let p = n_params();
        let v = [3.0_f64, 0.0, 0.0];
        let h = 1e-6;
        let e0 = m.eval(&v, &p);
        let e_h = m.eval(&[v[0] + h, v[1], v[2]], &p);
        let fd_gds = (e_h.g[0] - e0.g[0]) / h;
        let anal_gds =
            e0.G.iter()
                .find(|&&(r, c, _)| r == 0 && c == 0)
                .map(|&(_, _, v)| v)
                .unwrap_or(0.0);
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
        let e0 = m.eval(&v, &p);
        let e_h = m.eval(&[v[0], v[1] + h, v[2]], &p);
        let fd_gm = (e_h.g[0] - e0.g[0]) / h;
        let anal_gm =
            e0.G.iter()
                .find(|&&(r, c, _)| r == 0 && c == 1)
                .map(|&(_, _, v)| v)
                .unwrap_or(0.0);
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
        assert!(
            eval.g[0] < 0.0,
            "P-MESFET Ids should be negative: {}",
            eval.g[0]
        );
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
        p_vto.set("beta", 1e-3_f64);
        p_vto.set("vto", -0.8_f64); // alias
        p_vto.set("alpha", 2.0_f64);
        p_vto.set("lambda", 0.0_f64);
        p_vto.set("is_gate", 1e-14_f64);
        let e_vth = m.eval(&[3.0, 0.0, 0.0], &p_vth);
        let e_vto = m.eval(&[3.0, 0.0, 0.0], &p_vto);
        assert!(
            (e_vth.g[0] - e_vto.g[0]).abs() < 1e-20,
            "vth={} vto={}",
            e_vth.g[0],
            e_vto.g[0]
        );
    }

    // ── CGS/CGD capacitance tests ────────────────────────────────────────────

    /// CGS stamps charge on gate and source, CGD stamps charge on gate and drain.
    #[test]
    fn mesfet_cgs_cgd_stamps_q_and_c() {
        let m = Mesfet::nmos();
        // Vd=3, Vg=0, Vs=0  →  VGS_phys=0, VGD_phys=0-3=-3
        let voltages = [3.0_f64, 0.0, 0.0];

        let mut params = n_params();
        let cgs_val = 2e-12_f64;
        let cgd_val = 1e-12_f64;
        params.set("cgs", cgs_val);
        params.set("cgd", cgd_val);

        let eval = m.eval(&voltages[..], &params);

        let vgs_phys = voltages[1] - voltages[2]; // 0
        let vgd_phys = voltages[1] - voltages[0]; // -3
        let q_gs = cgs_val * vgs_phys; // 0
        let q_gd = cgd_val * vgd_phys; // -3e-12

        // Expected per-terminal charges:
        //   drain(0) = -Q_GD = +3e-12
        //   gate(1)  = Q_GS + Q_GD = 0 + (-3e-12) = -3e-12
        //   source(2)= -Q_GS = 0
        assert!(
            (eval.q[0] - (-q_gd)).abs() < 1e-25,
            "q[drain]={} expected {}",
            eval.q[0],
            -q_gd
        );
        assert!(
            (eval.q[1] - (q_gs + q_gd)).abs() < 1e-25,
            "q[gate]={} expected {}",
            eval.q[1],
            q_gs + q_gd
        );
        assert!(
            (eval.q[2] - (-q_gs)).abs() < 1e-25,
            "q[source]={} expected {}",
            eval.q[2],
            -q_gs
        );

        // KCL on charge: sum must be 0.
        let q_sum: f64 = eval.q.iter().sum();
        assert!(q_sum.abs() < 1e-30, "charge KCL violation: {q_sum}");

        // C Jacobian must have 7 entries (CGD contributes 4, CGS contributes 3
        // sharing the (1,1) entry).
        assert_eq!(eval.C.len(), 7, "C entries: {:?}", eval.C);

        // Find C[0,0] = CGD, C[1,1] = CGS+CGD, C[2,2] = CGS.
        let c00 = eval
            .C
            .iter()
            .find(|&&(r, c, _)| r == 0 && c == 0)
            .map(|&(_, _, v)| v)
            .unwrap_or(0.0);
        let c11 = eval
            .C
            .iter()
            .find(|&&(r, c, _)| r == 1 && c == 1)
            .map(|&(_, _, v)| v)
            .unwrap_or(0.0);
        let c22 = eval
            .C
            .iter()
            .find(|&&(r, c, _)| r == 2 && c == 2)
            .map(|&(_, _, v)| v)
            .unwrap_or(0.0);
        assert!((c00 - cgd_val).abs() < 1e-25, "C[0,0]={c00} expected CGD={cgd_val}");
        assert!(
            (c11 - (cgs_val + cgd_val)).abs() < 1e-25,
            "C[1,1]={c11} expected CGS+CGD={}",
            cgs_val + cgd_val
        );
        assert!((c22 - cgs_val).abs() < 1e-25, "C[2,2]={c22} expected CGS={cgs_val}");
    }

    /// Without CGS/CGD the C Jacobian is empty (no reactive stamping).
    #[test]
    fn mesfet_no_caps_empty_c() {
        let m = Mesfet::nmos();
        let params = n_params();
        let eval = m.eval(&[3.0, 0.0, 0.0], &params);
        assert!(eval.C.is_empty(), "C should be empty without CGS/CGD");
    }

    /// Charge vector must have 3 entries even without capacitances.
    #[test]
    fn mesfet_q_vector_length() {
        let m = Mesfet::nmos();
        let params = n_params();
        let eval = m.eval(&[3.0, 0.0, 0.0], &params);
        assert_eq!(eval.q.len(), 3, "q vector must have 3 entries");
    }
}
