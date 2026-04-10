use smallvec::{SmallVec, smallvec};
use pisim_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

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

impl DeviceModel for MosfetLevel1 {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let kp = params.get("kp").unwrap_or(2e-5);
        let vth = params.get("vto")
            .or_else(|| params.get("vth0"))
            .or_else(|| params.get("vth"))
            .unwrap_or(0.7);
        let lambda = params.get("lambda").unwrap_or(0.0);
        let w = params.get_or("w", 1e-6);
        let l = params.get_or("l", 1e-6);
        let beta = kp * w / l;

        let is_pmos = params.get_or("pmos", 0.0) != 0.0;
        let sign = if is_pmos { -1.0 } else { 1.0 };

        let vgs = sign * (voltages[1] - voltages[2]);
        let vds = sign * (voltages[0] - voltages[2]);

        // For PMOS, VTO is specified as negative in the netlist; use absolute value
        // since the sign convention is already handled by flipping vgs/vds.
        let vth_eff = if is_pmos { vth.abs() } else { vth };
        let vov = vgs - vth_eff;

        // Minimum drain-source conductance for well-conditioned Jacobians.
        // Added consistently to both id and gds so the Jacobian equals d(id)/d(vds).
        // Matches ngspice's GMIN (1e-12 S). The solver's targeted GMIN mechanism
        // handles weak diagonals during Newton iteration.
        // Max leakage: 1e-12 * 5V = 5pA (negligible).
        const GDS_MIN: f64 = 1e-12;

        let (id, gm, gds) = if vov <= 0.0 {
            // Cutoff — only GDS_MIN leakage.
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else if vds < vov {
            // Linear (triode) region.
            let id = beta * (vov * vds - 0.5 * vds * vds) * (1.0 + lambda * vds)
                + GDS_MIN * vds;
            let gm = beta * vds * (1.0 + lambda * vds);
            let gds = beta * (vov - vds) * (1.0 + lambda * vds)
                + beta * (vov * vds - 0.5 * vds * vds) * lambda
                + GDS_MIN;
            (id, gm, gds)
        } else {
            // Saturation region.
            let id = 0.5 * beta * vov * vov * (1.0 + lambda * vds)
                + GDS_MIN * vds;
            let gm = beta * vov * (1.0 + lambda * vds);
            let gds = 0.5 * beta * vov * vov * lambda + GDS_MIN;
            (id, gm, gds)
        };

        let id_signed = sign * id;

        // Jacobian: d(id_signed)/d(Vd) = sign * d(id)/d(vds) * d(vds)/d(Vd)
        //         = sign * gds * sign = gds  (sign cancels)
        // Same for gm. So conductance stamps use unsigned gm, gds.
        DeviceEval {
            g: smallvec![id_signed, 0.0, -id_signed, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0, gds),
                (0, 1, gm),
                (0, 2, -(gm + gds)),
                (2, 0, -gds),
                (2, 1, -gm),
                (2, 2, gm + gds),
            ],
            C: SmallVec::new(),
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
        let kp     = params.get_or("kp",     2e-5);
        let vto    = params.get("vto").or_else(|| params.get("vth0")).unwrap_or(0.7);
        let lambda = params.get_or("lambda", 0.0);
        let w      = params.get_or("w",      1e-6);
        let l      = params.get_or("l",      1e-6);
        let gamma  = params.get_or("gamma",  0.0);
        let phi    = params.get_or("phi",    0.6).max(0.1);
        let beta   = kp * w / l;

        let is_pmos = params.get_or("pmos", 0.0) != 0.0;
        let sign = if is_pmos { -1.0 } else { 1.0 };

        let vgs = sign * (voltages[1] - voltages[2]);
        let vds = sign * (voltages[0] - voltages[2]);
        let vbs = sign * (voltages[3] - voltages[2]);

        // Body effect: Vth = vto + gamma*(sqrt(phi + Vsb) - sqrt(phi))
        let vsb = -vbs;
        let sqrt_phi_vsb = (phi + vsb.max(-phi + 1e-12)).sqrt();
        let sqrt_phi     = phi.sqrt();
        let vth = if is_pmos {
            -(vto.abs()) + gamma * (sqrt_phi - sqrt_phi_vsb)
        } else {
            vto + gamma * (sqrt_phi_vsb - sqrt_phi)
        };

        let vov = vgs - vth;
        const GDS_MIN: f64 = 1e-12;

        let (id, gm, gds) = if vov <= 0.0 {
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else if vds < vov {
            let id  = beta * (vov * vds - 0.5 * vds * vds) * (1.0 + lambda * vds)
                    + GDS_MIN * vds;
            let gm  = beta * vds * (1.0 + lambda * vds);
            let gds = beta * (vov - vds) * (1.0 + lambda * vds)
                    + beta * (vov * vds - 0.5 * vds * vds) * lambda
                    + GDS_MIN;
            (id, gm, gds)
        } else {
            let id  = 0.5 * beta * vov * vov * (1.0 + lambda * vds)
                    + GDS_MIN * vds;
            let gm  = beta * vov * (1.0 + lambda * vds);
            let gds = 0.5 * beta * vov * vov * lambda + GDS_MIN;
            (id, gm, gds)
        };

        // Body-effect transconductance: gmb = gm * gamma / (2 * sqrt(phi + Vsb))
        let gmb = if sqrt_phi_vsb > 1e-6 {
            gm * gamma / (2.0 * sqrt_phi_vsb)
        } else {
            0.0
        };
        let id_signed = sign * id;

        DeviceEval {
            g: smallvec![id_signed, 0.0, -id_signed, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0,  gds),
                (0, 1,  gm),
                (0, 2, -(gm + gds + gmb)),
                (0, 3,  gmb),
                (2, 0, -gds),
                (2, 1, -gm),
                (2, 2,  gm + gds + gmb),
                (2, 3, -gmb),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize { 4 }

    fn kind(&self) -> DeviceKind { DeviceKind::MosfetN2 }
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
        let kp     = params.get_or("kp",     2e-5);
        let vto    = params.get("vto").or_else(|| params.get("vth0")).unwrap_or(0.7);
        let lambda = params.get_or("lambda", 0.0);
        let w      = params.get_or("w",      1e-6);
        let l      = params.get_or("l",      1e-6);
        let gamma  = params.get_or("gamma",  0.0);
        let phi    = params.get_or("phi",    0.6).max(0.1);
        let eta    = params.get_or("eta",    0.0);   // DIBL coefficient
        let theta  = params.get_or("theta",  0.0);  // mobility degradation
        let delta  = params.get_or("delta",  0.0);  // narrow-width effect
        let kappa  = params.get_or("kappa",  0.2);  // saturation field factor
        let beta0  = kp * w / l;

        let is_pmos = params.get_or("pmos", 0.0) != 0.0;
        let sign = if is_pmos { -1.0 } else { 1.0 };

        let vgs = sign * (voltages[1] - voltages[2]);
        let vds = sign * (voltages[0] - voltages[2]);
        let vbs = sign * (voltages[3] - voltages[2]);
        let vsb = -vbs;

        // Body effect + narrow-width (delta) + DIBL (eta)
        let sqrt_phi_vsb = (phi + vsb.max(-phi + 1e-12)).sqrt();
        let sqrt_phi     = phi.sqrt();
        let gamma_w = gamma
            + delta * std::f64::consts::PI * 3.9e-11 / (4.0 * l * sqrt_phi_vsb.max(1e-6));
        let vth = if is_pmos {
            -(vto.abs()) + gamma_w * (sqrt_phi - sqrt_phi_vsb) - eta * vds
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

        const GDS_MIN: f64 = 1e-12;
        let (id, gm, gds) = if vov <= 0.0 {
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else if vds < vdsat {
            let id  = beta * (vov * vds - 0.5 * vds * vds) * (1.0 + lambda * vds)
                    + GDS_MIN * vds;
            let gm  = beta * vds * (1.0 + lambda * vds);
            let gds = beta * (vov - vds) * (1.0 + lambda * vds)
                    + beta * (vov * vds - 0.5 * vds * vds) * lambda
                    + GDS_MIN;
            (id, gm, gds)
        } else {
            let id  = 0.5 * beta * vdsat * vdsat * (1.0 + lambda * vds)
                    + GDS_MIN * vds;
            let gm  = beta * vdsat * (1.0 + lambda * vds);
            let gds = 0.5 * beta * vdsat * vdsat * lambda + GDS_MIN;
            (id, gm, gds)
        };

        let gmb = if sqrt_phi_vsb > 1e-6 {
            gm * gamma_w / (2.0 * sqrt_phi_vsb)
        } else {
            0.0
        };
        // DIBL contribution to output conductance: d(Vth)/d(Vds) = -eta → gds gain
        let gds_eta = gm * eta;
        let gds_total = gds + gds_eta;
        let id_signed = sign * id;

        DeviceEval {
            g: smallvec![id_signed, 0.0, -id_signed, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0,  gds_total),
                (0, 1,  gm),
                (0, 2, -(gm + gds_total + gmb)),
                (0, 3,  gmb),
                (2, 0, -gds_total),
                (2, 1, -gm),
                (2, 2,  gm + gds_total + gmb),
                (2, 3, -gmb),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize { 4 }

    fn kind(&self) -> DeviceKind { DeviceKind::MosfetN3 }
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
        let ko     = params.get_or("ko",     1e-5);
        let mk     = params.get_or("mk",     2.0);
        let vto    = params.get("vto").or_else(|| params.get("vth0")).unwrap_or(0.7);
        let lambda = params.get_or("lambda", 0.0);
        let w      = params.get_or("w",      1e-6);
        let l      = params.get_or("l",      1e-6);

        let is_pmos = params.get_or("pmos", 0.0) != 0.0;
        let sign = if is_pmos { -1.0 } else { 1.0 };

        let vgs = sign * (voltages[1] - voltages[2]);
        let vds = sign * (voltages[0] - voltages[2]);
        let vth_eff = if is_pmos { vto.abs() } else { vto };
        let vov = vgs - vth_eff;

        const GDS_MIN: f64 = 1e-12;

        let (id, gm, gds) = if vov <= 0.0 {
            (GDS_MIN * vds, 0.0, GDS_MIN)
        } else {
            let wl = w / l;
            // Saturation current: id_sat = (W/L) * ko * Vov^mk
            let id_sat = wl * ko * vov.powf(mk);
            // Smooth linear→sat via tanh: id = id_sat * tanh(Vds/Vov) * (1 + lambda*Vds)
            let ratio = if vov > 1e-9 { (vds / vov).min(20.0) } else { 20.0_f64 };
            let thr   = ratio.tanh();
            let sech2 = 1.0 - thr * thr;
            let id   = id_sat * thr * (1.0 + lambda * vds) + GDS_MIN * vds;
            let gm   = wl * ko * mk * vov.powf(mk - 1.0) * thr * (1.0 + lambda * vds);
            let gds  = id_sat * sech2 / vov * (1.0 + lambda * vds)
                     + id_sat * thr * lambda
                     + GDS_MIN;
            (id, gm, gds)
        };

        let id_signed = sign * id;
        DeviceEval {
            g: smallvec![id_signed, 0.0, -id_signed, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0,  gds),
                (0, 1,  gm),
                (0, 2, -(gm + gds)),
                (2, 0, -gds),
                (2, 1, -gm),
                (2, 2,  gm + gds),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize { 4 }

    fn kind(&self) -> DeviceKind { DeviceKind::MosfetN6 }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let eval = m.eval(&[5.0, 0.3, 0.0, 0.0], &params);
        // In cutoff, id = GDS_MIN * Vds = 1e-12 * 5 = 5e-12
        assert!((eval.g[0]).abs() < 1e-10, "cutoff current {} too large", eval.g[0]);
    }

    #[test]
    fn nmos_saturation() {
        let m = MosfetLevel1;
        let params = nmos_params();
        let eval = m.eval(&[5.0, 2.0, 0.0, 0.0], &params);
        assert!(eval.g[0] > 0.0);
    }

    #[test]
    fn nmos_linear() {
        let m = MosfetLevel1;
        let params = nmos_params();
        let eval = m.eval(&[0.5, 2.0, 0.0, 0.0], &params);
        assert!(eval.g[0] > 0.0);
    }

    #[test]
    fn nmos_current_conservation() {
        let m = MosfetLevel1;
        let params = nmos_params();
        let eval = m.eval(&[3.0, 2.0, 0.0, 0.0], &params);
        assert!((eval.g[0] + eval.g[2]).abs() < 1e-20);
    }

    // ── Level 2 tests ──────────────────────────────────────────────────────

    #[test]
    fn mosfet_l2_body_effect() {
        // With gamma=0.5 and Vbs=-1 (Vsb=+1), Vth should exceed VTO=0.7
        let m = MosfetLevel2;
        let mut p = ParamMap::new();
        p.set("kp",     2e-5);
        p.set("vto",    0.7);
        p.set("gamma",  0.5);
        p.set("phi",    0.6);
        p.set("w",      10e-6);
        p.set("l",      1e-6);
        // voltages: [Vd, Vg, Vs, Vb] = [3.0, 2.0, 0.0, -1.0]
        // Vbs = -1.0 → Vsb = +1.0 → body effect raises Vth
        let eval_body = m.eval(&[3.0, 2.0, 0.0, -1.0], &p);
        // Without body effect (Vbs=0):
        let eval_no_body = m.eval(&[3.0, 2.0, 0.0, 0.0], &p);
        // Higher Vth → lower overdrive → lower current
        assert!(eval_body.g[0] < eval_no_body.g[0],
            "body effect should reduce Id: {} >= {}", eval_body.g[0], eval_no_body.g[0]);
    }

    #[test]
    fn mosfet_l2_no_body_effect() {
        // gamma=0 → Level 2 should behave identically to Level 1
        let m1 = MosfetLevel1;
        let m2 = MosfetLevel2;
        let mut p = ParamMap::new();
        p.set("kp",    2e-5);
        p.set("vto",   0.7);
        p.set("gamma", 0.0);
        p.set("phi",   0.6);
        p.set("w",     10e-6);
        p.set("l",     1e-6);
        // saturation
        let e1 = m1.eval(&[5.0, 2.0, 0.0, 0.0], &p);
        let e2 = m2.eval(&[5.0, 2.0, 0.0, 0.0], &p);
        assert!((e1.g[0] - e2.g[0]).abs() < 1e-15,
            "L2 with gamma=0 should match L1: {} vs {}", e1.g[0], e2.g[0]);
    }

    // ── Level 3 tests ──────────────────────────────────────────────────────

    #[test]
    fn mosfet_l3_dibl() {
        // DIBL: eta > 0 lowers Vth at higher Vds → higher Id
        let m = MosfetLevel3;
        let mut p = ParamMap::new();
        p.set("kp",    2e-5);
        p.set("vto",   0.7);
        p.set("gamma", 0.0);
        p.set("phi",   0.6);
        p.set("eta",   0.1);
        p.set("w",     10e-6);
        p.set("l",     1e-6);
        // Same Vgs, different Vds — higher Vds should give more current with eta>0
        let eval_hi_vds = m.eval(&[2.0, 2.0, 0.0, 0.0], &p);
        let eval_lo_vds = m.eval(&[1.0, 2.0, 0.0, 0.0], &p);
        assert!(eval_hi_vds.g[0] > eval_lo_vds.g[0],
            "DIBL should boost Id at higher Vds");
    }

    #[test]
    fn mosfet_l3_current_conservation() {
        let m = MosfetLevel3;
        let mut p = ParamMap::new();
        p.set("kp", 2e-5);
        p.set("vto", 0.7);
        p.set("w", 10e-6);
        p.set("l", 1e-6);
        let eval = m.eval(&[3.0, 2.0, 0.0, 0.0], &p);
        assert!((eval.g[0] + eval.g[2]).abs() < 1e-20);
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
        let eval = m.eval(&[5.0, 2.0, 0.0, 0.0], &p);
        assert!(eval.g[0] > 0.0, "Level 6 should produce current in saturation");
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
        let eval = m.eval(&[3.0, 2.0, 0.0, 0.0], &p);
        assert!((eval.g[0] + eval.g[2]).abs() < 1e-20);
    }
}
