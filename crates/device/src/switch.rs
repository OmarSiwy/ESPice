use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Voltage-controlled switch (S element): 4-terminal device.
///
/// Pin 0 = output+, Pin 1 = output-, Pin 2 = control+, Pin 3 = control-.
/// Model params: `vt` (threshold), `vh` (hysteresis half-width), `ron`, `roff`.
///
/// The switch stamps using a smooth tanh conductance transition to avoid
/// hard nonlinearities that cause Newton-Raphson convergence failures near
/// threshold.  The ngspice-compatible formula is:
///
///   G(vc) = (Gon + Goff)/2 + (Gon - Goff)/2 * tanh(3 * (vc - vt) / vh_eff)
///
/// where `vh_eff = max(vh, 0.1)` ensures smoothness even when vh == 0.
///
/// The hysteretic `state` param (0.0 = OFF, 1.0 = ON) shifts the effective
/// threshold: when ON the centre is `vt - vh`; when OFF it is `vt + vh`.
/// This preserves the correct hysteretic operating region while keeping the
/// transition smooth for the Newton solver.
///
/// The Jacobian includes four standard conductance entries plus four
/// cross-terms coupling control voltage to output current (dG/dVc * Vout).
#[derive(Debug, Clone, Copy)]
pub struct Switch;

impl DeviceModel for Switch {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let vt = params.get_or("vt", 0.0);
        let vh = params.get_or("vh", 0.0);
        let ron = params.get_or("ron", 1.0);
        let roff = params.get_or("roff", 1e12);
        let state = params.get_or("state", 0.0); // 0.0 = OFF, 1.0 = ON

        let vc = voltages[2] - voltages[3];

        // Hysteretic centre: when ON use vt - vh, when OFF use vt + vh.
        // This keeps the tanh centred in the correct half of the hysteresis
        // window while remaining continuous within that window.
        let vt_eff = if state != 0.0 { vt - vh } else { vt + vh };

        // Minimum half-width prevents a degenerate (discontinuous) tanh when
        // the user specifies vh = 0.  0.1 V matches ngspice's internal epsilon.
        let vh_eff = vh.max(0.1);

        let gon = 1.0 / ron;
        let goff = 1.0 / roff;

        let arg = 3.0 * (vc - vt_eff) / vh_eff;
        let th = arg.tanh();
        let g = 0.5 * (gon + goff) + 0.5 * (gon - goff) * th;

        // dG/dVc = (Gon - Goff)/2 * 3/vh_eff * (1 - tanh^2)
        let dg_dvc = 0.5 * (gon - goff) * (3.0 / vh_eff) * (1.0 - th * th);

        let vout = voltages[0] - voltages[1];
        let iout = g * vout;

        DeviceEval {
            g: smallvec![iout, -iout, 0.0, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            // Standard conductance terms (output port self-admittance).
            // Cross-terms: d(G*Vout)/dVc = dG/dVc * Vout, with correct sign
            // for differential control voltage (pin 2 = ctrl+, pin 3 = ctrl-).
            G: smallvec![
                (0, 0,  g),
                (0, 1, -g),
                (1, 0, -g),
                (1, 1,  g),
                (0, 2,  dg_dvc * vout),
                (0, 3, -dg_dvc * vout),
                (1, 2, -dg_dvc * vout),
                (1, 3,  dg_dvc * vout),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Switch
    }
}

/// Current-controlled switch (W element): 4-terminal device.
///
/// Pin 0 = output+, Pin 1 = output-, Pin 2 = sense+, Pin 3 = sense-.
/// The control current is the branch current of a named sense V-source.
///
/// The stamper resolves the sense V-source's MNA branch index (stored by the
/// parser as param `ctrl_branch_index`) and writes the current value into
/// param `controlling_current` before calling `eval` each Newton iteration.
///
/// Model params: `it` (threshold current), `ih` (hysteresis half-width),
/// `ron`, `roff`, `state` (0.0 = OFF, 1.0 = ON).
///
/// Uses the same smooth tanh conductance model as `Switch` to avoid hard
/// nonlinearities in the Newton solver near the switching threshold.
/// The CSwitch has no control-port Jacobian cross-terms (unlike Switch) because
/// the controlling current is an external branch variable that is not among
/// this device's four output pins.
#[derive(Debug, Clone, Copy)]
pub struct CSwitch;

impl DeviceModel for CSwitch {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let it = params.get_or("it", 0.0);
        let ih = params.get_or("ih", 0.0);
        let ron = params.get_or("ron", 1.0);
        let roff = params.get_or("roff", 1e12);
        let state = params.get_or("state", 0.0);

        // Controlling current injected by the stamper each NR iteration.
        let ic = params.get_or("controlling_current", 0.0);

        // Hysteretic centre: when ON use it - ih, when OFF use it + ih.
        let it_eff = if state != 0.0 { it - ih } else { it + ih };

        // Minimum half-width prevents degenerate tanh when ih == 0.
        let ih_eff = ih.max(1e-6);

        let gon = 1.0 / ron;
        let goff = 1.0 / roff;

        let arg = 3.0 * (ic - it_eff) / ih_eff;
        let th = arg.tanh();
        let g = 0.5 * (gon + goff) + 0.5 * (gon - goff) * th;

        let vout = voltages[0] - voltages[1];
        let iout = g * vout;

        // No cross-terms for the controlling current: the sense branch current
        // lives at a global MNA index that is not among this device's local pins.
        // The smooth model still improves convergence by making G(ic) continuous.
        DeviceEval {
            g: smallvec![iout, -iout, 0.0, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0,  g),
                (0, 1, -g),
                (1, 0, -g),
                (1, 1,  g),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::CSwitch
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sw_params(vt: f64, vh: f64, ron: f64, roff: f64, state: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("vt", vt);
        p.set("vh", vh);
        p.set("ron", ron);
        p.set("roff", roff);
        p.set("state", state);
        p
    }

    /// Compute the expected smooth conductance for a given control voltage.
    fn smooth_g(vt: f64, vh: f64, ron: f64, roff: f64, state: f64, vc: f64) -> f64 {
        let vt_eff = if state != 0.0 { vt - vh } else { vt + vh };
        let vh_eff = vh.max(0.1);
        let gon = 1.0 / ron;
        let goff = 1.0 / roff;
        let arg = 3.0 * (vc - vt_eff) / vh_eff;
        0.5 * (gon + goff) + 0.5 * (gon - goff) * arg.tanh()
    }

    #[test]
    fn switch_off_high_resistance() {
        let sw = Switch;
        // Vc = 0 V, vt=1, vh=0.5, state=OFF → vt_eff=1.5, arg=3*(0-1.5)/0.5=-9
        // tanh(-9) ≈ -1 → g ≈ Goff = 1e-12
        let params = sw_params(1.0, 0.5, 1.0, 1e12, 0.0);
        let eval = sw.eval(&[1.0, 0.0, 0.0, 0.0], &params);
        let g_expected = smooth_g(1.0, 0.5, 1.0, 1e12, 0.0, 0.0);
        // tanh(-9) saturates very close to -1; g should be within 1e-4 of Goff
        assert!((eval.g[0] - g_expected * 1.0).abs() < 1e-10,
            "g[0]={} expected≈{}", eval.g[0], g_expected);
        assert!((eval.g[1] + g_expected * 1.0).abs() < 1e-10);
    }

    #[test]
    fn switch_on_low_resistance() {
        let sw = Switch;
        // Vc = 3 V, vt=1, vh=0.5, state=OFF → vt_eff=1.5, arg=3*(3-1.5)/0.5=9
        // tanh(9) ≈ 1 → g ≈ Gon = 0.1
        let params = sw_params(1.0, 0.5, 10.0, 1e12, 0.0);
        let eval = sw.eval(&[5.0, 0.0, 3.0, 0.0], &params);
        let g_expected = smooth_g(1.0, 0.5, 10.0, 1e12, 0.0, 3.0);
        // arg=9: tanh saturates; g within 1e-3 of Gon=0.1; iout = g*5
        assert!((eval.g[0] - g_expected * 5.0).abs() < 1e-10,
            "g[0]={} expected≈{}", eval.g[0], g_expected * 5.0);
    }

    #[test]
    fn switch_hysteresis_stays_on() {
        let sw = Switch;
        // State=ON, Vc=0.8 V, vt=1, vh=0.5 → vt_eff=0.5, arg=3*(0.8-0.5)/0.5=1.8
        // Switch is above ON-centre; g should be > midpoint (biased toward Gon).
        let params = sw_params(1.0, 0.5, 10.0, 1e12, 1.0);
        let eval = sw.eval(&[5.0, 0.0, 0.8, 0.0], &params);
        let g_expected = smooth_g(1.0, 0.5, 10.0, 1e12, 1.0, 0.8);
        let gon = 1.0 / 10.0;
        let gmid = 0.5 * (gon + 1e-12);
        // With arg=1.8, tanh≈0.947, so g is strongly biased toward Gon
        assert!(g_expected > gmid, "g_expected={} should be > gmid={}", g_expected, gmid);
        assert!((eval.g[0] - g_expected * 5.0).abs() < 1e-10);
    }

    #[test]
    fn switch_hysteresis_turns_off() {
        let sw = Switch;
        // State=ON, Vc=0.4 V < vt_eff=0.5 → negative arg; g biased toward Goff.
        // With arg=3*(0.4-0.5)/0.5=-0.6, tanh≈-0.537: g is between Goff and Gmid.
        let params = sw_params(1.0, 0.5, 10.0, 1e12, 1.0);
        let eval = sw.eval(&[1.0, 0.0, 0.4, 0.0], &params);
        let g_expected = smooth_g(1.0, 0.5, 10.0, 1e12, 1.0, 0.4);
        let gmid = 0.5 * (1.0 / 10.0 + 1e-12);
        // g should be below midpoint (trending toward Goff)
        assert!(g_expected < gmid, "g_expected={} should be < gmid={}", g_expected, gmid);
        assert!((eval.g[0] - g_expected * 1.0).abs() < 1e-10);
    }

    #[test]
    fn switch_num_terminals() {
        assert_eq!(Switch.num_terminals(), 4);
        assert_eq!(CSwitch.num_terminals(), 4);
    }

    #[test]
    fn switch_kind() {
        assert_eq!(Switch.kind(), DeviceKind::Switch);
        assert_eq!(CSwitch.kind(), DeviceKind::CSwitch);
    }

    #[test]
    fn switch_no_branch() {
        assert!(!Switch.needs_branch());
        assert!(!CSwitch.needs_branch());
    }

    #[test]
    fn cswitch_off_below_threshold() {
        let sw = CSwitch;
        let mut p = ParamMap::new();
        p.set("it", 0.01);
        // Use a nonzero ih so the tanh is well-conditioned; control current well
        // below threshold so g saturates near Goff.
        p.set("ih", 0.005);
        p.set("ron", 1.0);
        p.set("roff", 1e9);
        p.set("state", 0.0);
        p.set("controlling_current", 0.001); // far below it + ih = 0.015
        let eval = sw.eval(&[1.0, 0.0, 0.0, 0.0], &p);
        // arg = 3*(0.001 - 0.015)/0.005 = -8.4; tanh ≈ -1 → g ≈ Goff = 1e-9
        let g = eval.g[0]; // vout=1, so iout=g
        assert!(g < 2e-9, "g={} should be near Goff=1e-9", g);
    }

    #[test]
    fn cswitch_on_above_threshold() {
        let sw = CSwitch;
        let mut p = ParamMap::new();
        p.set("it", 0.01);
        p.set("ih", 0.005);
        p.set("ron", 100.0);
        p.set("roff", 1e9);
        p.set("state", 0.0);
        p.set("controlling_current", 0.025); // far above it + ih = 0.015
        let eval = sw.eval(&[1.0, 0.0, 0.0, 0.0], &p);
        // arg = 3*(0.025 - 0.015)/0.005 = 6; tanh ≈ 1 → g ≈ Gon = 0.01
        let gon = 1.0 / 100.0;
        assert!((eval.g[0] - gon).abs() < 1e-4,
            "g[0]={} expected≈Gon={}", eval.g[0], gon);
    }

    #[test]
    fn switch_jacobian_structure() {
        let sw = Switch;
        // Far above threshold: vc=3 >> vt+vh=1.5; well into ON region.
        let params = sw_params(1.0, 0.5, 10.0, 1e12, 0.0);
        let eval = sw.eval(&[5.0, 0.0, 3.0, 0.0], &params);
        // Smooth model produces 8 Jacobian entries: 4 conductance + 4 cross-terms.
        assert_eq!(eval.G.len(), 8, "expected 8 Jacobian entries");
        // First four entries: standard self-admittance block (output pins).
        let g = eval.G[0].2; // G[0,0]
        assert!(g > 0.0, "diagonal G should be positive");
        assert_eq!(eval.G[0].0, 0); assert_eq!(eval.G[0].1, 0);
        assert_eq!(eval.G[1].0, 0); assert_eq!(eval.G[1].1, 1);
        assert_eq!(eval.G[2].0, 1); assert_eq!(eval.G[2].1, 0);
        assert_eq!(eval.G[3].0, 1); assert_eq!(eval.G[3].1, 1);
        assert!((eval.G[1].2 + g).abs() < 1e-15, "G[0,1] should be -G[0,0]");
        assert!((eval.G[2].2 + g).abs() < 1e-15, "G[1,0] should be -G[0,0]");
        assert!((eval.G[3].2 - g).abs() < 1e-15, "G[1,1] should be +G[0,0]");
        // Cross-term pin indices: (0,2), (0,3), (1,2), (1,3)
        assert_eq!(eval.G[4].0, 0); assert_eq!(eval.G[4].1, 2);
        assert_eq!(eval.G[5].0, 0); assert_eq!(eval.G[5].1, 3);
        assert_eq!(eval.G[6].0, 1); assert_eq!(eval.G[6].1, 2);
        assert_eq!(eval.G[7].0, 1); assert_eq!(eval.G[7].1, 3);
        // Cross-terms: dG/dVc * Vout. Far above threshold tanh≈1 → dG/dVc≈0.
        // Values should be very small (nearly zero) for arg=9.
        let cross = eval.G[4].2.abs();
        assert!(cross < 1e-3, "cross-term far from threshold should be small, got {}", cross);
    }

    #[test]
    fn switch_smooth_at_threshold() {
        // At exactly the threshold the tanh is 0 → g = (Gon+Goff)/2.
        // dG/dVc is maximum here → cross-terms are nonzero.
        let sw = Switch;
        // state=OFF, vt=1, vh=0.5 → vt_eff=1.5; vc=vt_eff=1.5 for mid-point.
        let params = sw_params(1.0, 0.5, 10.0, 1e12, 0.0);
        let eval = sw.eval(&[2.0, 0.0, 1.5, 0.0], &params); // vout=2
        let gon = 0.1_f64;
        let goff = 1e-12_f64;
        let g_mid = 0.5 * (gon + goff);
        assert!((eval.G[0].2 - g_mid).abs() < 1e-15,
            "at threshold G[0,0] should equal (Gon+Goff)/2 = {}, got {}", g_mid, eval.G[0].2);
        // Cross-terms are nonzero at threshold (peak of dG/dVc).
        assert!(eval.G[4].2.abs() > 1e-3,
            "cross-term at threshold should be significant, got {}", eval.G[4].2);
    }
}
