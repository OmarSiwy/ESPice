//! SPICE-style per-device junction voltage limiting.
//!
//! Prevents Newton-Raphson from overshooting across device nonlinearities
//! (exponential PN junctions, MOSFET region boundaries). Each device limits
//! its own junction voltages relative to the previous iteration before
//! evaluation, matching the standard SPICE `pnjlim` / `DEVfetlim` approach.
//!
//! The limiting only affects what the device "sees" during evaluation — the
//! solution vector is not modified. At convergence, limited voltages equal
//! raw voltages (no change between iterations), so the solution is exact.

use bigospice_core::{DeviceKind, ParamMap};

/// Thermal voltage at ~300K (same as diode.rs).
const VT: f64 = 0.02585;

/// SPICE PN junction voltage limiting (`pnjlim`).
///
/// Prevents Newton steps from overshooting across the exponential knee.
/// When the new junction voltage exceeds `vcrit` and the step exceeds `2*vt`,
/// the step is compressed logarithmically so the device stays in a region
/// where the Jacobian is informative.
#[inline]
pub fn pnjlim(v_new: f64, v_old: f64, vt: f64, vcrit: f64) -> f64 {
    if v_new > vcrit && (v_new - v_old).abs() > 2.0 * vt {
        if v_old > 0.0 {
            let arg = 1.0 + (v_new - v_old) / vt;
            if arg > 0.0 {
                v_old + vt * (2.0 + arg.ln())
            } else {
                vcrit
            }
        } else {
            // v_old <= 0, jump to above vcrit: use log compression
            vt * (v_new / vt).ln()
        }
    } else {
        v_new
    }
}

/// SPICE MOSFET gate-source voltage limiting (`DEVfetlim`).
///
/// Limits Vgs changes per Newton iteration to prevent jumping across
/// cutoff / triode / saturation region boundaries. The allowed step size
/// is proportional to the overdrive voltage — larger steps are allowed
/// when the device is deep in strong inversion.
#[inline]
pub fn fetlim(vgs_new: f64, vgs_old: f64, vto: f64) -> f64 {
    let delv = vgs_new - vgs_old;

    if vgs_old >= vto {
        // Was in strong inversion — allow steps proportional to overdrive
        let vtsthi = (2.0 * (vgs_old - vto)).abs() + 2.0;
        if delv.abs() >= vtsthi {
            if delv > 0.0 {
                vgs_old + vtsthi
            } else {
                vgs_old - vtsthi
            }
        } else {
            vgs_new
        }
    } else {
        // Was below threshold — use tighter limits
        let vtsthi = (2.0 * (vgs_old - vto)).abs() + 2.0;
        let vtstlo = vtsthi / 2.0 + 2.0;
        if delv.abs() >= vtstlo {
            if delv > 0.0 {
                vgs_old + vtstlo
            } else {
                vgs_old - vtstlo
            }
        } else {
            vgs_new
        }
    }
}

/// SPICE MOSFET drain-source voltage limiting (`DEVlimvds`).
///
/// Limits Vds changes to prevent large swings at high-impedance drain nodes
/// (e.g., current-mirror-loaded outputs with lambda=0).
#[inline]
pub fn limvds(vds_new: f64, vds_old: f64) -> f64 {
    let delv = vds_new - vds_old;
    if delv.abs() > 3.5 {
        if delv > 0.0 {
            vds_old + 3.5
        } else {
            vds_old - 3.5
        }
    } else {
        vds_new
    }
}

/// Compute the SPICE critical voltage for a PN junction.
#[inline]
fn vcrit(nvt: f64, is: f64) -> f64 {
    nvt * (nvt / (std::f64::consts::SQRT_2 * is)).ln()
}

/// Apply per-device junction voltage limiting to terminal voltages.
///
/// Given new and old terminal voltages for a device, returns limited
/// voltages that prevent Newton from overshooting device nonlinearities.
/// Only diodes, BJTs, and MOSFETs are limited; linear devices pass through unchanged.
pub fn limit_junction_voltages(
    kind: DeviceKind,
    new_v: &[f64],
    old_v: &[f64],
    params: &ParamMap,
) -> smallvec::SmallVec<[f64; 4]> {
    let mut lim: smallvec::SmallVec<[f64; 4]> = new_v.iter().copied().collect();

    match kind {
        DeviceKind::Diode => {
            let is = params.get_or("is", 1e-14);
            let n = params.get_or("n", 1.0);
            let nvt = n * VT;
            let vc = vcrit(nvt, is);

            let vd_new = new_v[0] - new_v[1];
            let vd_old = old_v[0] - old_v[1];
            let vd_lim = pnjlim(vd_new, vd_old, nvt, vc);

            // Apply correction to anode (pin 0), keeping cathode unchanged.
            let correction = vd_lim - vd_new;
            if correction.abs() > 1e-15 {
                lim[0] += correction;
            }
        }
        DeviceKind::BjtNpn | DeviceKind::BjtPnp => {
            // Post-B001 pin layout:
            //   3-terminal: 0=C, 1=B, 2=E
            //   7-terminal: 0=extC, 1=extB, 2=extE, 3=sub, 4=intC', 5=intB', 6=intE'
            // Limit the INTRINSIC junction voltages (internal nodes) when available,
            // falling back to external pins for the 3-terminal case.
            let is = params.get_or("is", 1e-16);
            let nf = params.get_or("nf", 1.0);   // forward emission coefficient (BE)
            let nr = params.get_or("nr", 1.0);   // reverse emission coefficient (BC)
            let nvt_f = nf * VT;
            let nvt_r = nr * VT;
            let vc_f = vcrit(nvt_f, is);
            let vc_r = vcrit(nvt_r, is);

            let (b_pin, e_pin, c_pin) = if new_v.len() >= 7 {
                (5usize, 6usize, 4usize) // intB', intE', intC'
            } else {
                (1usize, 2usize, 0usize) // extB, extE, extC
            };

            // Vbe = Vb - Ve — forward junction, use nf
            let vbe_new = new_v[b_pin] - new_v[e_pin];
            let vbe_old = old_v[b_pin] - old_v[e_pin];
            let vbe_lim = pnjlim(vbe_new, vbe_old, nvt_f, vc_f);

            // Vbc = Vb - Vc — reverse junction, use nr
            let vbc_new = new_v[b_pin] - new_v[c_pin];
            let vbc_old = old_v[b_pin] - old_v[c_pin];
            let vbc_lim = pnjlim(vbc_new, vbc_old, nvt_r, vc_r);

            // Apply BE correction to emitter: Vbe_lim = Vb - Ve → delta_Ve = -(vbe_lim - vbe_new)
            let be_corr = vbe_lim - vbe_new;
            if be_corr.abs() > 1e-15 {
                lim[e_pin] -= be_corr;
            }

            // Apply BC correction to collector independently: delta_Vc = -(vbc_lim - vbc_new)
            let bc_corr = vbc_lim - vbc_new;
            if bc_corr.abs() > 1e-15 {
                lim[c_pin] -= bc_corr;
            }
        }
        DeviceKind::MosfetN | DeviceKind::MosfetP
        | DeviceKind::MosfetN2 | DeviceKind::MosfetP2
        | DeviceKind::MosfetN3 | DeviceKind::MosfetP3
        | DeviceKind::MosfetN6 | DeviceKind::MosfetP6 => {
            let is_pmos = matches!(kind, DeviceKind::MosfetP | DeviceKind::MosfetP2
                                       | DeviceKind::MosfetP3 | DeviceKind::MosfetP6)
                || params.get_or("pmos", 0.0) != 0.0;
            let sign = if is_pmos { -1.0 } else { 1.0 };

            let vth = params
                .get("vto")
                .or_else(|| params.get("vth0"))
                .or_else(|| params.get("vth"))
                .unwrap_or(0.7);
            let vth_eff = if is_pmos { vth.abs() } else { vth };

            // Pin 0=drain, 1=gate, 2=source, 3=bulk
            let vgs_new_raw = sign * (new_v[1] - new_v[2]);
            let vgs_old_raw = sign * (old_v[1] - old_v[2]);
            let vds_new_raw = sign * (new_v[0] - new_v[2]);
            let vds_old_raw = sign * (old_v[0] - old_v[2]);

            // Source-drain swap: when Vds < 0 the model internally swaps
            // D and S, so the effective gate voltage is Vgd, not Vgs.
            // Apply fetlim to the effective gate voltage that the model
            // will actually use.
            let reversed = vds_new_raw < 0.0;
            let (vgs_new, vgs_old, vds_new, vds_old) = if reversed {
                (vgs_new_raw - vds_new_raw, vgs_old_raw - vds_old_raw,
                 -vds_new_raw, -vds_old_raw)
            } else {
                (vgs_new_raw, vgs_old_raw, vds_new_raw, vds_old_raw)
            };

            let vgs_lim = fetlim(vgs_new, vgs_old, vth_eff);
            let _vds_lim = limvds(vds_new, vds_old);

            // Apply Vgs correction via the source node (pin 2).
            // In the normal case: Vgs = sign*(Vg - Vs), correct Vs.
            // In the reversed case: effective Vgs = Vgd = sign*(Vg - Vd),
            //   so the correction should be applied to the drain node (pin 0).
            let vgs_corr = vgs_lim - vgs_new;
            if vgs_corr.abs() > 1e-15 {
                if reversed {
                    // Vgd = sign*(Vg - Vd) → to change Vgd by delta, change Vd by -sign*delta.
                    lim[0] -= sign * vgs_corr;
                } else {
                    // Vgs = sign*(Vg - Vs) → to change Vgs by delta, change Vs by -sign*delta.
                    lim[2] -= sign * vgs_corr;
                }
            }

            // Apply Vds correction via the drain node (pin 0).
            // Vds = sign*(Vd - Vs_lim) => to change Vds by delta, change Vd by sign*delta.
            let vds_adj = sign * (new_v[0] - lim[2]);
            let vds_adj_eff = if reversed { -vds_adj } else { vds_adj };
            let vds_lim2 = limvds(vds_adj_eff, vds_old);
            let vds_corr = vds_lim2 - vds_adj_eff;
            if vds_corr.abs() > 1e-15 {
                if reversed {
                    lim[0] -= sign * vds_corr;
                } else {
                    lim[0] += sign * vds_corr;
                }
            }
        }
        _ => {}
    }

    lim
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pnjlim_no_limit_below_vcrit() {
        let nvt = 0.02585;
        let vc = vcrit(nvt, 1e-14);
        // Small voltage below vcrit — no limiting
        assert_eq!(pnjlim(0.5, 0.4, nvt, vc), 0.5);
    }

    #[test]
    fn pnjlim_limits_large_step_above_vcrit() {
        let nvt = 0.02585;
        let vc = vcrit(nvt, 1e-14);
        // Large jump from 0.7 to 10.0 — should be compressed
        let limited = pnjlim(10.0, 0.7, nvt, vc);
        assert!(limited < 10.0, "should limit: got {limited}");
        assert!(limited > 0.7, "should not go below old: got {limited}");
    }

    #[test]
    fn pnjlim_small_step_above_vcrit_passes() {
        let nvt = 0.02585;
        let vc = vcrit(nvt, 1e-14);
        // Small step above vcrit — no limiting needed
        let limited = pnjlim(0.75, 0.73, nvt, vc);
        assert!((limited - 0.75).abs() < 1e-15);
    }

    #[test]
    fn fetlim_small_step_passes() {
        // Small Vgs change — no limiting
        assert_eq!(fetlim(1.5, 1.4, 0.7), 1.5);
    }

    #[test]
    fn fetlim_limits_large_step_in_strong_inversion() {
        // Device at Vgs=2.0 (well above Vto=0.7), jump to 10.0
        let limited = fetlim(10.0, 2.0, 0.7);
        assert!(limited < 10.0, "should limit: got {limited}");
        assert!(limited > 2.0, "should not go below old: got {limited}");
    }

    #[test]
    fn fetlim_limits_large_step_below_threshold() {
        // Device below threshold (Vgs=0.3, Vto=0.7), jump to 5.0
        let limited = fetlim(5.0, 0.3, 0.7);
        assert!(limited < 5.0, "should limit: got {limited}");
    }

    #[test]
    fn limvds_small_step_passes() {
        assert_eq!(limvds(3.0, 2.5), 3.0);
    }

    #[test]
    fn limvds_limits_large_step() {
        let limited = limvds(10.0, 2.0);
        assert!((limited - 5.5).abs() < 1e-15);
    }

    #[test]
    fn limit_junction_voltages_resistor_passthrough() {
        let params = ParamMap::new();
        let new_v = [5.0, 2.0];
        let old_v = [3.0, 1.0];
        let lim = limit_junction_voltages(DeviceKind::Resistor, &new_v, &old_v, &params);
        assert_eq!(lim.as_slice(), &[5.0, 2.0]);
    }

    #[test]
    fn limit_junction_voltages_diode_limits() {
        let mut params = ParamMap::new();
        params.set("is", 1e-14);
        params.set("n", 1.0);
        let new_v = [10.0, 0.0]; // Vd = 10V — huge jump
        let old_v = [0.7, 0.0]; // Vd_old = 0.7V
        let lim = limit_junction_voltages(DeviceKind::Diode, &new_v, &old_v, &params);
        // Anode should be limited
        assert!(lim[0] < 10.0, "should limit anode: got {}", lim[0]);
        assert!(lim[0] > 0.7, "should not go below old: got {}", lim[0]);
        // Cathode unchanged
        assert_eq!(lim[1], 0.0);
    }

    #[test]
    fn limit_junction_voltages_nmos_limits() {
        let mut params = ParamMap::new();
        params.set("vto", 0.7);
        // Pin 0=drain, 1=gate, 2=source, 3=bulk
        let new_v = [10.0, 2.0, 0.0, 0.0]; // large Vds jump
        let old_v = [2.0, 2.0, 0.0, 0.0];
        let lim = limit_junction_voltages(DeviceKind::MosfetN, &new_v, &old_v, &params);
        // Drain should be limited (Vds jump from 2 to 10 > 3.5)
        assert!(lim[0] < 10.0, "should limit drain: got {}", lim[0]);
    }
}
