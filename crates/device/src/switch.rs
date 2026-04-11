use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Voltage-controlled switch (S element): 4-terminal device.
///
/// Pin 0 = output+, Pin 1 = output-, Pin 2 = control+, Pin 3 = control-.
/// Model params: `vt` (threshold), `vh` (hysteresis), `ron`, `roff`.
///
/// The switch stamps as a linear conductance:
///   G = 1/ron  when ON  (Vc > vt + vh → turn on, Vc < vt - vh → turn off)
///   G = 1/roff when OFF
///
/// The `state` param (0.0 = OFF, 1.0 = ON) carries the current state.
/// Newton iterations within a single time-point are performed with a fixed
/// state; the state is updated between time-points by the caller or the
/// parser-built default.
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

        // Hysteretic state update: transition only when crossing a threshold.
        let is_on = if state != 0.0 {
            // Currently ON: stay ON unless Vc drops below vt - vh
            vc >= vt - vh
        } else {
            // Currently OFF: turn ON only if Vc rises above vt + vh
            vc >= vt + vh
        };

        let r = if is_on { ron } else { roff };
        let g = 1.0 / r;

        let vout = voltages[0] - voltages[1];
        let iout = g * vout;

        DeviceEval {
            g: smallvec![iout, -iout, 0.0, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0, g),
                (0, 1, -g),
                (1, 0, -g),
                (1, 1, g),
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
/// The control current is the current through the sense element (a V-source
/// in series). In MNA, this is the branch current of the sense V-source.
///
/// The sense current is passed as a terminal voltage at pin 2 (convention
/// used by the stamper: pin 2 carries the controlling branch current value
/// when `eval_with_branch` is called with that value).
///
/// Simplification: the stamper evaluates the switch by passing the controlling
/// current directly in the `voltages` slice at index 2.  The parser sets
/// param `"controlling_current"` to the sampled I(vname) value each Newton
/// iteration.
///
/// Model params: `it` (threshold current), `ih` (hysteresis), `ron`, `roff`.
#[derive(Debug, Clone, Copy)]
pub struct CSwitch;

impl DeviceModel for CSwitch {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let it = params.get_or("it", 0.0);
        let ih = params.get_or("ih", 0.0);
        let ron = params.get_or("ron", 1.0);
        let roff = params.get_or("roff", 1e12);
        let state = params.get_or("state", 0.0);

        // Controlling current passed as param (updated by stamper each NR iter).
        let ic = params.get_or("controlling_current", 0.0);

        let is_on = if state != 0.0 {
            ic >= it - ih
        } else {
            ic >= it + ih
        };

        let r = if is_on { ron } else { roff };
        let g = 1.0 / r;

        let vout = voltages[0] - voltages[1];
        let iout = g * vout;

        DeviceEval {
            g: smallvec![iout, -iout, 0.0, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 0, g),
                (0, 1, -g),
                (1, 0, -g),
                (1, 1, g),
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

    #[test]
    fn switch_off_high_resistance() {
        let sw = Switch;
        // Vc = 0 V < vt + vh = 1.5 V → OFF
        let params = sw_params(1.0, 0.5, 1.0, 1e12, 0.0);
        let eval = sw.eval(&[1.0, 0.0, 0.0, 0.0], &params);
        // iout = g * vout = 1e-12 * 1.0
        assert!((eval.g[0] - 1e-12).abs() < 1e-20);
        assert!((eval.g[1] + 1e-12).abs() < 1e-20);
    }

    #[test]
    fn switch_on_low_resistance() {
        let sw = Switch;
        // Vc = 3 V > vt + vh = 1.5 V → ON
        let params = sw_params(1.0, 0.5, 10.0, 1e12, 0.0);
        let eval = sw.eval(&[5.0, 0.0, 3.0, 0.0], &params);
        // g = 1/10 = 0.1; iout = 0.1 * 5 = 0.5
        assert!((eval.g[0] - 0.5).abs() < 1e-12);
    }

    #[test]
    fn switch_hysteresis_stays_on() {
        let sw = Switch;
        // State = ON (1.0), Vc = 0.8 V, vt - vh = 0.5 V → stays ON
        let params = sw_params(1.0, 0.5, 10.0, 1e12, 1.0);
        let eval = sw.eval(&[5.0, 0.0, 0.8, 0.0], &params);
        assert!((eval.g[0] - 0.5).abs() < 1e-12);
    }

    #[test]
    fn switch_hysteresis_turns_off() {
        let sw = Switch;
        // State = ON (1.0), Vc = 0.4 V < vt - vh = 0.5 V → turns OFF
        let params = sw_params(1.0, 0.5, 10.0, 1e12, 1.0);
        let eval = sw.eval(&[1.0, 0.0, 0.4, 0.0], &params);
        assert!((eval.g[0] - 1e-12).abs() < 1e-20);
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
    fn cswitch_off_by_default() {
        let sw = CSwitch;
        let mut p = ParamMap::new();
        p.set("it", 0.01);
        p.set("ih", 0.0);
        p.set("ron", 1.0);
        p.set("roff", 1e9);
        p.set("state", 0.0);
        p.set("controlling_current", 0.005); // below threshold
        let eval = sw.eval(&[1.0, 0.0, 0.0, 0.0], &p);
        // g = 1/1e9 = 1e-9
        assert!((eval.g[0] - 1e-9).abs() < 1e-18);
    }

    #[test]
    fn cswitch_on_above_threshold() {
        let sw = CSwitch;
        let mut p = ParamMap::new();
        p.set("it", 0.01);
        p.set("ih", 0.0);
        p.set("ron", 100.0);
        p.set("roff", 1e9);
        p.set("state", 0.0);
        p.set("controlling_current", 0.02); // above threshold
        let eval = sw.eval(&[1.0, 0.0, 0.0, 0.0], &p);
        // g = 1/100 = 0.01; iout = 0.01 * 1.0 = 0.01
        assert!((eval.g[0] - 0.01).abs() < 1e-12);
    }

    #[test]
    fn switch_jacobian_consistency() {
        let sw = Switch;
        let params = sw_params(1.0, 0.5, 10.0, 1e12, 0.0);
        // ON state: Vc > vt + vh
        let eval = sw.eval(&[5.0, 0.0, 3.0, 0.0], &params);
        let g = 1.0 / 10.0;
        assert_eq!(eval.G.len(), 4);
        assert!((eval.G[0].2 - g).abs() < 1e-15);
        assert!((eval.G[1].2 + g).abs() < 1e-15);
        assert!((eval.G[2].2 + g).abs() < 1e-15);
        assert!((eval.G[3].2 - g).abs() < 1e-15);
    }
}
