use smallvec::{SmallVec, smallvec};
use pisim_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Lossless transmission line model (Branin's method).
///
/// SPICE syntax: `T<name> n1 0 n2 0 Z0=50 TD=1n`
///
/// Pin layout:
///   pin 0 = port-1 positive node (n1+)
///   pin 1 = port-1 negative node (n1-)
///   pin 2 = port-2 positive node (n2+)
///   pin 3 = port-2 negative node (n2-)
///   pin 4 = branch current variable for port-1 Thevenin V-source
///   pin 5 = branch current variable for port-2 Thevenin V-source
///
/// # Branin's companion model
///
/// At each port, the lossless T-line presents a Thevenin equivalent:
///
///   V_p1(t) = Z0 * I_p1(t) + E_hist_p1
///   V_p2(t) = Z0 * I_p2(t) + E_hist_p2
///
/// where `E_hist_p1 = V_p2(t - TD) + Z0 * I_p2(t - TD)` is the delayed
/// incident wave arriving from port 2, and vice versa.
///
/// The delayed values `E_hist` are provided externally by the stamper (which
/// has access to the circuit's `TlineHistory` store) via the `rhs` field.
///
/// **This model is STATELESS** — the history lookup is injected through
/// `params` keys `e_hist_p1` and `e_hist_p2`.  The stamper fills these
/// before each eval from `Circuit::tline_history`.
///
/// ## MNA stamp (per port, shown for port 1)
///
/// Each port gets a Thevenin V-source in series with Z0:
///
///   V(n1+) - V(n1-) = Z0 * I_br1 + E_hist_p1
///
/// Which stamps as:
///   - KCL row n1+: +I_br1  →  residual += I_br1; G(n1+, br1) += 1
///   - KCL row n1-: -I_br1  →  residual -= I_br1; G(n1-, br1) += -1
///   - Branch eq:  V(n1+) - V(n1-) - Z0*I_br1 = E_hist_p1
///       residual[br1] = V(n1+) - V(n1-) - Z0*I_br1
///       G(br1, n1+) = 1, G(br1, n1-) = -1, G(br1, br1) = -Z0
///       rhs[0] = E_hist_p1  (subtracted in stamper: residual[br1] -= rhs[0])
///
/// Port 2 is identical with pin indices shifted by 2 (nodes) and 1 (branch).
#[derive(Debug, Clone, Copy)]
pub struct Tline;

impl DeviceModel for Tline {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        // Branch currents default to 0 — use eval_with_branch for MNA.
        self.eval_with_branch(voltages, 0.0, params)
    }

    fn eval_with_branch(
        &self,
        voltages: &[f64],
        _branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        let z0 = params.get_or("z0", 50.0);

        // Port voltages: pins 0,1 = port1 n+/n-; pins 2,3 = port2 n+/n-.
        let vp1 = voltages.get(0).copied().unwrap_or(0.0);
        let vn1 = voltages.get(1).copied().unwrap_or(0.0);
        let vp2 = voltages.get(2).copied().unwrap_or(0.0);
        let vn2 = voltages.get(3).copied().unwrap_or(0.0);

        // Branch currents: pin 4 = I_br1, pin 5 = I_br2.
        // In MNA the branch variables live beyond the terminal pins, so voltages
        // slice is [vp1, vn1, vp2, vn2] and branch currents come from the
        // solution vector.  We receive them via separate indices; for the
        // residual here we use the value directly from the solution array if
        // available (the stamper passes them as extras after the terminal voltages).
        let i_br1 = voltages.get(4).copied().unwrap_or(0.0);
        let i_br2 = voltages.get(5).copied().unwrap_or(0.0);

        // Delayed incident waves (injected by the stamper via params).
        let e_hist_p1 = params.get_or("e_hist_p1", 0.0);
        let e_hist_p2 = params.get_or("e_hist_p2", 0.0);

        // g contributions (residuals):
        //   Row 0 (KCL at n1+): +I_br1
        //   Row 1 (KCL at n1-): -I_br1
        //   Row 2 (KCL at n2+): +I_br2
        //   Row 3 (KCL at n2-): -I_br2
        //   Row 4 (branch eq1): V(n1+) - V(n1-) - Z0*I_br1  (rhs subtracts E_hist_p1)
        //   Row 5 (branch eq2): V(n2+) - V(n2-) - Z0*I_br2  (rhs subtracts E_hist_p2)
        let branch_eq1 = (vp1 - vn1) - z0 * i_br1;
        let branch_eq2 = (vp2 - vn2) - z0 * i_br2;

        DeviceEval {
            g: smallvec![i_br1, -i_br1, i_br2, -i_br2, branch_eq1, branch_eq2],
            q: smallvec![0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            #[allow(non_snake_case)]
            G: smallvec![
                // Port 1 KCL stamps
                (0, 4, 1.0),    // dg[0]/dI_br1 = +1
                (1, 4, -1.0),   // dg[1]/dI_br1 = -1
                // Port 2 KCL stamps
                (2, 5, 1.0),    // dg[2]/dI_br2 = +1
                (3, 5, -1.0),   // dg[3]/dI_br2 = -1
                // Branch equation 1 Jacobian
                (4, 0, 1.0),    // dg[4]/dV(n1+) = +1
                (4, 1, -1.0),   // dg[4]/dV(n1-) = -1
                (4, 4, -z0),    // dg[4]/dI_br1  = -Z0
                // Branch equation 2 Jacobian
                (5, 2, 1.0),    // dg[5]/dV(n2+) = +1
                (5, 3, -1.0),   // dg[5]/dV(n2-) = -1
                (5, 5, -z0),    // dg[5]/dI_br2  = -Z0
            ],
            C: SmallVec::new(),
            // rhs: [E_hist_p1, E_hist_p2] — branch equation constraints.
            // The stamper adds rhs[i] to the branch equation row residual.
            rhs: smallvec![e_hist_p1, e_hist_p2],
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn needs_branch(&self) -> bool {
        // The T-line needs TWO branch variables (one per port), but the existing
        // DeviceInstance infrastructure supports a single `branch_index`.
        // We handle this by using branch_index as the FIRST branch (port 1)
        // and branch_index+1 as port 2.  The stamper is aware of this.
        true
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Tline
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_params(z0: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("z0", z0);
        p.set("td", 1e-9);
        p
    }

    fn make_params_with_hist(z0: f64, e1: f64, e2: f64) -> ParamMap {
        let mut p = make_params(z0);
        p.set("e_hist_p1", e1);
        p.set("e_hist_p2", e2);
        p
    }

    #[test]
    fn tline_z0_stamp_matched_load() {
        // With matched load (Z0 = 50 Ω on both sides) and no history (cold line),
        // the branch equations should enforce V(n+) - V(n-) = Z0 * I_br.
        let tline = Tline;
        let z0 = 50.0;
        let params = make_params_with_hist(z0, 0.0, 0.0);

        // Suppose V(n1+)=1V, V(n1-)=0V, I_br1=0.02A → V=Z0*I → satisfied.
        // branch_eq1 = (1.0 - 0.0) - 50*0.02 = 0
        let voltages = [1.0_f64, 0.0, 0.5, 0.0, 0.02, 0.01];
        let eval = tline.eval_with_branch(&voltages, 0.0, &params);

        // KCL rows
        assert!((eval.g[0] - 0.02).abs() < 1e-15);  // +I_br1
        assert!((eval.g[1] + 0.02).abs() < 1e-15);  // -I_br1
        assert!((eval.g[2] - 0.01).abs() < 1e-15);  // +I_br2
        assert!((eval.g[3] + 0.01).abs() < 1e-15);  // -I_br2

        // Branch equations: V - Z0*I - E_hist
        let expected_br1 = (1.0 - 0.0) - 50.0 * 0.02;  // = 0
        let expected_br2 = (0.5 - 0.0) - 50.0 * 0.01;  // = 0
        assert!((eval.g[4] - expected_br1).abs() < 1e-14);
        assert!((eval.g[5] - expected_br2).abs() < 1e-14);
    }

    #[test]
    fn tline_jacobian_entries() {
        let tline = Tline;
        let z0 = 75.0;
        let params = make_params_with_hist(z0, 0.0, 0.0);
        let voltages = [0.0_f64; 6];
        let eval = tline.eval_with_branch(&voltages, 0.0, &params);

        // Verify all 10 G stamps are present.
        assert_eq!(eval.G.len(), 10);

        // Port 1 KCL: (0,4,+1), (1,4,-1)
        assert!(eval.G.contains(&(0, 4, 1.0)));
        assert!(eval.G.contains(&(1, 4, -1.0)));
        // Port 2 KCL: (2,5,+1), (3,5,-1)
        assert!(eval.G.contains(&(2, 5, 1.0)));
        assert!(eval.G.contains(&(3, 5, -1.0)));
        // Branch eq 1: (4,0,1), (4,1,-1), (4,4,-Z0)
        assert!(eval.G.contains(&(4, 0, 1.0)));
        assert!(eval.G.contains(&(4, 1, -1.0)));
        assert!(eval.G.contains(&(4, 4, -z0)));
        // Branch eq 2: (5,2,1), (5,3,-1), (5,5,-Z0)
        assert!(eval.G.contains(&(5, 2, 1.0)));
        assert!(eval.G.contains(&(5, 3, -1.0)));
        assert!(eval.G.contains(&(5, 5, -z0)));
    }

    #[test]
    fn tline_rhs_carries_history() {
        let tline = Tline;
        let params = make_params_with_hist(50.0, 1.5, 0.8);
        let voltages = [0.0_f64; 6];
        let eval = tline.eval_with_branch(&voltages, 0.0, &params);

        assert_eq!(eval.rhs.len(), 2);
        assert!((eval.rhs[0] - 1.5).abs() < 1e-15);
        assert!((eval.rhs[1] - 0.8).abs() < 1e-15);
    }

    #[test]
    fn tline_kind_and_terminals() {
        let tline = Tline;
        assert_eq!(tline.kind(), DeviceKind::Tline);
        assert_eq!(tline.num_terminals(), 4);
        assert!(tline.needs_branch());
    }

    #[test]
    fn tline_history_push_and_interpolate() {
        use pisim_core::TlineHistory;

        let mut hist = TlineHistory::new(50.0, 1e-9, 16);

        // Push a ramp: E increases linearly from 0 to 1V over 0..10ns.
        for i in 0..=10 {
            let t = i as f64 * 1e-9;
            hist.push_p1(t, t * 1e9); // slope = 1V/ns
        }

        // Interpolate at t = 3.5ns → E should be ~3.5
        let e = TlineHistory::interpolate(&hist.samples_p1, 3.5e-9);
        assert!((e - 3.5).abs() < 0.1, "interpolated {e}, expected ~3.5");
    }

    #[test]
    fn tline_history_delayed_lookup() {
        use pisim_core::TlineHistory;

        let td = 2e-9_f64;
        let mut hist = TlineHistory::new(50.0, td, 32);

        // Store E(t) = t * 1e9  (1V per ns)
        for i in 0..=20 {
            let t = i as f64 * 1e-9;
            hist.push_p2(t, t * 1e9);
        }

        // delayed_p2 at t=5ns should return E(5ns - 2ns) = E(3ns) ≈ 3.0
        let delayed = hist.delayed_p2(5e-9);
        assert!(
            (delayed - 3.0).abs() < 0.5,
            "delayed_p2 = {delayed}, expected ~3.0"
        );
    }
}
