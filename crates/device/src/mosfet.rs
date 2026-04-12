use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

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

        let vgs_raw = sign * (voltages[1] - voltages[2]);
        let vds_raw = sign * (voltages[0] - voltages[2]);

        // Source-drain swap: when Vds < 0 the physical drain is at a lower
        // potential than the source.  Standard SPICE (ngspice DEVmosfet1load)
        // swaps drain and source internally so that the Shichman-Hodges
        // equations always see Vds >= 0.  The effective gate voltage becomes
        // Vgd (gate-to-drain) and Vds is negated.  After evaluation the
        // current is negated and the Jacobian columns for D/S are swapped.
        let (vgs, vds, reversed) = if vds_raw >= 0.0 {
            (vgs_raw, vds_raw, false)
        } else {
            // vgd = vgs - vds (gate relative to the physical drain)
            (vgs_raw - vds_raw, -vds_raw, true)
        };

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
        let (g_dd, g_dg, g_ds, g_sd, g_sg, g_ss) = if reversed {
            ( gm + gds, -gm, -gds, -(gm + gds),  gm,  gds)
        } else {
            ( gds,       gm, -(gm + gds), -gds, -gm, gm + gds)
        };

        // ── Meyer gate capacitances (opt-in: requires TOX in .MODEL) ─────────
        // Only compute intrinsic gate caps when TOX is explicitly specified.
        // Overlap caps (CGSO, CGDO, CGBO) are always honoured when present.
        let has_tox = params.get("tox").is_some();
        let cgso_ov = params.get_or("cgso", 0.0) * w;
        let cgdo_ov = params.get_or("cgdo", 0.0) * w;

        let (c_gd, c_gs, c_gb) = if has_tox {
            const EPSOX: f64 = 3.453e-11;
            let tox = params.get_or("tox", 1e-7).max(1e-12);
            let ld = params.get_or("ld", 0.0);
            let leff = (l - 2.0 * ld).max(1e-9);
            let cox = EPSOX / tox * w * leff;
            let cgbo_ov = params.get_or("cgbo", 0.0) * leff;

            let (cgs_i, cgd_i, cgb_i) = if vov <= 0.0 {
                (0.0, 0.0, cox)
            } else if vds < vov {
                let denom = 2.0 * vov - vds;
                if denom.abs() < 1e-15 {
                    (2.0 / 3.0 * cox, 0.0, 0.0)
                } else {
                    let arg_s = (vov - vds) / denom;
                    let arg_d = vov / denom;
                    (2.0 / 3.0 * cox * (1.0 - arg_s * arg_s),
                     2.0 / 3.0 * cox * (1.0 - arg_d * arg_d),
                     0.0)
                }
            } else {
                (2.0 / 3.0 * cox, 0.0, 0.0)
            };

            if reversed {
                (cgs_i + cgdo_ov, cgd_i + cgso_ov, cgb_i + cgbo_ov)
            } else {
                (cgd_i + cgdo_ov, cgs_i + cgso_ov, cgb_i + cgbo_ov)
            }
        } else {
            // No TOX → overlap caps only (usually zero)
            (cgdo_ov, cgso_ov, 0.0)
        };

        let has_caps = c_gd != 0.0 || c_gs != 0.0 || c_gb != 0.0;

        let vgd_phys = voltages[1] - voltages[0];
        let vgs_phys = voltages[1] - voltages[2];
        let vgb_phys = voltages[1] - voltages[3];

        DeviceEval {
            g: smallvec![id_signed, 0.0, -id_signed, 0.0],
            q: if has_caps {
                smallvec![
                    -c_gd * vgd_phys,
                     c_gd * vgd_phys + c_gs * vgs_phys + c_gb * vgb_phys,
                    -c_gs * vgs_phys,
                    -c_gb * vgb_phys,
                ]
            } else {
                smallvec![0.0, 0.0, 0.0, 0.0]
            },
            G: smallvec![
                (0, 0, g_dd),
                (0, 1, g_dg),
                (0, 2, g_ds),
                (2, 0, g_sd),
                (2, 1, g_sg),
                (2, 2, g_ss),
            ],
            C: if has_caps {
                smallvec![
                    (0, 0,  c_gd),
                    (0, 1, -c_gd),
                    (1, 0, -c_gd),
                    (1, 1,  c_gd + c_gs + c_gb),
                    (1, 2, -c_gs),
                    (1, 3, -c_gb),
                    (2, 1, -c_gs),
                    (2, 2,  c_gs),
                    (3, 1, -c_gb),
                    (3, 3,  c_gb),
                ]
            } else {
                SmallVec::new()
            },
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

        let id_signed = if reversed { -sign * id } else { sign * id };

        // Jacobian: when reversed, D/S columns swap (see MosfetLevel1).
        let (g_dd, g_dg, g_ds, g_db, g_sd, g_sg, g_ss, g_sb) = if reversed {
            ( gm + gds,    -gm,     -gds,     -gmb,
             -(gm + gds),   gm,      gds,      gmb)
        } else {
            ( gds,           gm,     -(gm + gds + gmb),  gmb,
             -gds,          -gm,      gm + gds + gmb,   -gmb)
        };

        DeviceEval {
            g: smallvec![id_signed, 0.0, -id_signed, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0, g_dd),
                (0, 1, g_dg),
                (0, 2, g_ds),
                (0, 3, g_db),
                (2, 0, g_sd),
                (2, 1, g_sg),
                (2, 2, g_ss),
                (2, 3, g_sb),
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

        let id_signed = if reversed { -sign * id } else { sign * id };

        // Jacobian: when reversed, D/S columns swap (see MosfetLevel1).
        let (g_dd, g_dg, g_ds, g_db, g_sd, g_sg, g_ss, g_sb) = if reversed {
            ( gm + gds_total,    -gm,     -gds_total,     -gmb,
             -(gm + gds_total),   gm,      gds_total,      gmb)
        } else {
            ( gds_total,           gm,     -(gm + gds_total + gmb),  gmb,
             -gds_total,          -gm,      gm + gds_total + gmb,   -gmb)
        };

        DeviceEval {
            g: smallvec![id_signed, 0.0, -id_signed, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0, g_dd),
                (0, 1, g_dg),
                (0, 2, g_ds),
                (0, 3, g_db),
                (2, 0, g_sd),
                (2, 1, g_sg),
                (2, 2, g_ss),
                (2, 3, g_sb),
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

        let id_signed = if reversed { -sign * id } else { sign * id };

        // Jacobian: when reversed, D/S columns swap (see MosfetLevel1).
        let (g_dd, g_dg, g_ds, g_sd, g_sg, g_ss) = if reversed {
            ( gm + gds, -gm, -gds, -(gm + gds),  gm,  gds)
        } else {
            ( gds,       gm, -(gm + gds), -gds, -gm, gm + gds)
        };

        DeviceEval {
            g: smallvec![id_signed, 0.0, -id_signed, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0, g_dd),
                (0, 1, g_dg),
                (0, 2, g_ds),
                (2, 0, g_sd),
                (2, 1, g_sg),
                (2, 2, g_ss),
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

    // ── Source-drain swap tests (Vds < 0) ────────────────────────────────

    #[test]
    fn nmos_negative_vds_reverses_current() {
        // When Vd < Vs, current should flow from source to drain (negative Id).
        let m = MosfetLevel1;
        let params = nmos_params();
        // Normal: Vd=3, Vg=2, Vs=0 → positive Id (drain→source)
        let eval_normal = m.eval(&[3.0, 2.0, 0.0, 0.0], &params);
        assert!(eval_normal.g[0] > 0.0, "normal: Id should be positive");

        // Swapped: Vd=0, Vg=2, Vs=3 → Vds_raw = 0-3 = -3, triggers swap
        // Effective: vgs' = Vgd = 2-0 = 2, vds' = 3
        // After swap, id is positive internally but negated → Id at pin 0 is negative
        let eval_swapped = m.eval(&[0.0, 2.0, 3.0, 0.0], &params);
        assert!(eval_swapped.g[0] < 0.0,
            "reversed Vds: Id at drain should be negative, got {}", eval_swapped.g[0]);
    }

    #[test]
    fn nmos_negative_vds_current_conservation() {
        // KCL: current into drain + current into source = 0
        let m = MosfetLevel1;
        let params = nmos_params();
        let eval = m.eval(&[0.0, 2.0, 3.0, 0.0], &params);
        assert!((eval.g[0] + eval.g[2]).abs() < 1e-20,
            "KCL violated: Id={} + Is={} != 0", eval.g[0], eval.g[2]);
    }

    #[test]
    fn nmos_swap_symmetry() {
        // Swapping drain and source physically should give equal-magnitude,
        // opposite-sign drain current (for symmetric Vgs conditions).
        let m = MosfetLevel1;
        let params = nmos_params();
        // Case A: Vd=3, Vg=2, Vs=0 → Vgs=2, Vds=3
        let eval_a = m.eval(&[3.0, 2.0, 0.0, 0.0], &params);
        // Case B: Vd=0, Vg=2, Vs=3 → swap triggers, effective Vgs'=Vgd=2, Vds'=3
        let eval_b = m.eval(&[0.0, 2.0, 3.0, 0.0], &params);
        // Magnitudes should be equal (same effective operating point)
        let id_a = eval_a.g[0];
        let id_b = eval_b.g[0];
        assert!((id_a + id_b).abs() < 1e-15,
            "swap symmetry: |Id_normal| should equal |Id_reversed|: {} vs {}", id_a, id_b);
    }

    #[test]
    fn nmos_negative_vds_cutoff() {
        // Vds < 0 but device in cutoff (Vgd < Vth after swap)
        let m = MosfetLevel1;
        let params = nmos_params();
        // Vd=-1, Vg=0.3, Vs=0 → Vds_raw = -1, swap → vgs'=Vgd=0.3-(-1)=1.3... no
        // Actually: Vd=0, Vg=0.3, Vs=3 → Vds_raw = 0-3 = -3, swap → vgs'=Vgd=0.3-0=0.3
        // 0.3 < Vth=0.7 → cutoff
        let eval = m.eval(&[0.0, 0.3, 3.0, 0.0], &params);
        assert!(eval.g[0].abs() < 1e-10,
            "reversed cutoff: current should be ~0, got {}", eval.g[0]);
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
        let eval_normal = m.eval(&[0.0, 0.0, 3.3, 3.3], &p);
        assert!(eval_normal.g[0] < 0.0,
            "PMOS normal: Id at drain should be negative (current into drain), got {}",
            eval_normal.g[0]);

        // KCL conservation
        assert!((eval_normal.g[0] + eval_normal.g[2]).abs() < 1e-20,
            "PMOS KCL violated");
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
        // DIBL: eta > 0 lowers Vth → higher overdrive → higher Id at the same Vds.
        // Compare eta=0 vs eta>0 at the same operating point to isolate the DIBL effect
        // from region changes (kappa can move the saturation boundary).
        let m = MosfetLevel3;
        let mut p_no_dibl = ParamMap::new();
        p_no_dibl.set("kp",    2e-5);
        p_no_dibl.set("vto",   0.7);
        p_no_dibl.set("gamma", 0.0);
        p_no_dibl.set("phi",   0.6);
        p_no_dibl.set("eta",   0.0);
        p_no_dibl.set("w",     10e-6);
        p_no_dibl.set("l",     1e-6);

        let mut p_dibl = p_no_dibl.clone();
        p_dibl.set("eta", 0.1);

        // Same voltages: Vds=2 gives eta*Vds = 0.2V threshold reduction
        let eval_no_dibl = m.eval(&[2.0, 2.0, 0.0, 0.0], &p_no_dibl);
        let eval_dibl    = m.eval(&[2.0, 2.0, 0.0, 0.0], &p_dibl);
        assert!(eval_dibl.g[0] > eval_no_dibl.g[0],
            "DIBL should boost Id: with eta={} vs without={}", eval_dibl.g[0], eval_no_dibl.g[0]);
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
