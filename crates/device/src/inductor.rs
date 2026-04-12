use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Linear inductor: 2-terminal device with a branch current variable (MNA).
///
/// Pin 0 = positive terminal, Pin 1 = negative terminal.
/// Branch index = 2 (the branch current row in the local system).
/// Parameter: `inductance` (henries).
///
/// MNA formulation:
///   KCL at pin 0: ... + I_branch = 0
///   KCL at pin 1: ... - I_branch = 0
///   Branch equation: V0 - V1 = L * dI_branch/dt
///
/// In the g/q framework the transient residual is
///   F = g + alpha*(q - q_prev)           (alpha = 1/h for BE)
///
/// Setting F[branch]=0 must recover V0-V1 = L*dI/dt.  With alpha=1/h:
///   (V0-V1) + (1/h)*( q[2] - q_prev[2] ) = 0
///   (V0-V1) + (1/h)*(-L*I + L*I_prev)    = 0
///   (V0-V1) = (L/h)*(I - I_prev)  =  L * dI/dt   ✓
///
/// Therefore q[2] = **-L** * I_branch  (note the minus sign).
///
///   g[0] = +I_branch, g[1] = -I_branch, g[2] = V0 - V1  (branch eq residual)
///   q[2] = -L * I_branch  (reactive term — sign chosen so F=0 ⇒ V=L·dI/dt)
///   G stamps: (0,2,+1), (1,2,-1), (2,0,+1), (2,1,-1)
///   C stamps: (2,2, -L)
#[derive(Debug, Clone, Copy)]
pub struct Inductor;

impl DeviceModel for Inductor {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        // Without branch current, we can only stamp the voltage part.
        self.eval_with_branch(voltages, 0.0, params)
    }

    fn eval_with_branch(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        let l = params.get_or("inductance", 1e-3);
        let v0 = voltages[0];
        let v1 = voltages[1];
        let i_br = branch_current;

        // g contributions:
        //   Row 0 (KCL at pin 0): +I_branch
        //   Row 1 (KCL at pin 1): -I_branch
        //   Row 2 (branch equation): V0 - V1  (the residual of V0-V1 - L*dI/dt = 0)
        //     In DC (dI/dt=0): V0-V1 = 0, so residual = V0-V1
        let g_branch_eq = v0 - v1;

        // q contributions:
        //   Row 2 (branch equation): -L * I_branch
        //   With the BE residual F = g + (1/h)*(q - q_prev), setting F=0 gives
        //     V0-V1 = (L/h)*(I - I_prev) = L * dI/dt    (correct sign).
        let q_branch = -l * i_br;

        DeviceEval {
            g: smallvec![i_br, -i_br, g_branch_eq],
            q: smallvec![0.0, 0.0, q_branch],
            G: smallvec![
                (0, 2, 1.0),   // dg[0]/dI_branch = +1
                (1, 2, -1.0),  // dg[1]/dI_branch = -1
                (2, 0, 1.0),   // dg[2]/dV0 = +1
                (2, 1, -1.0),  // dg[2]/dV1 = -1
            ],
            C: smallvec![
                (2, 2, -l),    // dq[2]/dI_branch = -L
            ],
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn needs_branch(&self) -> bool {
        true
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Inductor
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_params(l: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("inductance", l);
        p
    }

    #[test]
    fn inductor_mna_stamps() {
        let ind = Inductor;
        let params = make_params(1e-3);
        let eval = ind.eval_with_branch(&[5.0, 2.0], 0.01, &params);

        // g: [I_br, -I_br, V0-V1]
        assert!((eval.g[0] - 0.01).abs() < 1e-15);
        assert!((eval.g[1] + 0.01).abs() < 1e-15);
        assert!((eval.g[2] - 3.0).abs() < 1e-15);

        // q: [0, 0, -L*I_br]
        assert!((eval.q[0]).abs() < 1e-15);
        assert!((eval.q[1]).abs() < 1e-15);
        assert!((eval.q[2] - (-1e-3 * 0.01)).abs() < 1e-15);
    }

    #[test]
    fn inductor_g_jacobian() {
        let ind = Inductor;
        let params = make_params(1e-3);
        let eval = ind.eval_with_branch(&[1.0, 0.0], 0.0, &params);

        // G stamps: (0,2,+1), (1,2,-1), (2,0,+1), (2,1,-1)
        assert_eq!(eval.G.len(), 4);
        assert_eq!(eval.G[0], (0, 2, 1.0));
        assert_eq!(eval.G[1], (1, 2, -1.0));
        assert_eq!(eval.G[2], (2, 0, 1.0));
        assert_eq!(eval.G[3], (2, 1, -1.0));
    }

    #[test]
    fn inductor_c_jacobian() {
        let l = 4.7e-3;
        let ind = Inductor;
        let params = make_params(l);
        let eval = ind.eval_with_branch(&[0.0, 0.0], 0.0, &params);

        assert_eq!(eval.C.len(), 1);
        assert_eq!(eval.C[0].0, 2);
        assert_eq!(eval.C[0].1, 2);
        assert!((eval.C[0].2 - (-l)).abs() < 1e-15);
    }

    #[test]
    fn inductor_needs_branch() {
        let ind = Inductor;
        assert!(ind.needs_branch());
    }

    #[test]
    fn inductor_finite_difference_g() {
        let ind = Inductor;
        let params = make_params(1e-3);
        let h = 1e-7;
        let i_br = 0.05;

        let v = [3.0, 1.0];
        let eval0 = ind.eval_with_branch(&v, i_br, &params);

        // Perturb V0
        let eval_pv0 = ind.eval_with_branch(&[v[0] + h, v[1]], i_br, &params);
        let dg2_dv0 = (eval_pv0.g[2] - eval0.g[2]) / h;
        assert!((dg2_dv0 - 1.0).abs() < 1e-6);

        // Perturb V1
        let eval_pv1 = ind.eval_with_branch(&[v[0], v[1] + h], i_br, &params);
        let dg2_dv1 = (eval_pv1.g[2] - eval0.g[2]) / h;
        assert!((dg2_dv1 + 1.0).abs() < 1e-6);

        // Perturb I_branch
        let eval_pi = ind.eval_with_branch(&v, i_br + h, &params);
        let dg0_di = (eval_pi.g[0] - eval0.g[0]) / h;
        let dg1_di = (eval_pi.g[1] - eval0.g[1]) / h;
        assert!((dg0_di - 1.0).abs() < 1e-6);
        assert!((dg1_di + 1.0).abs() < 1e-6);
    }

    #[test]
    fn inductor_finite_difference_q() {
        let l = 2.2e-3;
        let ind = Inductor;
        let params = make_params(l);
        let h = 1e-7;
        let i_br = 0.1;

        let v = [1.0, 0.0];
        let eval0 = ind.eval_with_branch(&v, i_br, &params);

        // Perturb I_branch for q[2]  (q[2] = -L*I, so dq2/dI = -L)
        let eval_pi = ind.eval_with_branch(&v, i_br + h, &params);
        let dq2_di = (eval_pi.q[2] - eval0.q[2]) / h;
        assert!((dq2_di - (-l)).abs() < 1e-6 * l);
    }
}
