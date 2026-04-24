//! Companion model helpers for transient analysis.
//!
//! Implements Backward Euler (and Trapezoidal) discretization of reactive contributions.
//! For Backward Euler at timestep `h`:
//!   F(x_{n+1}) = g(x_{n+1}) + (1/h) * ( q(x_{n+1}) - q(x_n) ) - sources(t_{n+1})
//!   J = G + (1/h) * C
//!
//! ## BDF coefficient tables
//!
//! BDF-k approximates x'_n as a linear combination of the k+1 most recent
//! solution points. Standard form:
//!   sum_{j=0}^{k} alpha_j * x_{n-j} = h * beta_0 * f_n

use incspice_solver::linalg::{DenseVec, TripletMatrix};

/// Time integration method recognised by the companion solver.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompanionMethod {
    BackwardEuler,
    Trapezoidal,
    Gear2,
    Gear3,
    Gear4,
    Gear5,
}

/// BDF-k history coefficients.
pub struct BdfCoeffs {
    pub alpha: f64,
    pub history: [f64; 5],
    pub history_len: usize,
}

impl CompanionMethod {
    /// Number of historical solution slots required.
    #[inline]
    pub fn history_depth(self) -> usize {
        match self {
            CompanionMethod::BackwardEuler => 1,
            CompanionMethod::Trapezoidal => 1,
            CompanionMethod::Gear2 => 2,
            CompanionMethod::Gear3 => 3,
            CompanionMethod::Gear4 => 4,
            CompanionMethod::Gear5 => 5,
        }
    }

    /// The factor `alpha` such that `J = G + alpha*C`.
    #[inline]
    pub fn alpha(self, h: f64) -> f64 {
        match self {
            CompanionMethod::BackwardEuler => 1.0 / h,
            CompanionMethod::Trapezoidal => 2.0 / h,
            CompanionMethod::Gear2 => 3.0 / (2.0 * h),
            CompanionMethod::Gear3 => 11.0 / (6.0 * h),
            CompanionMethod::Gear4 => 25.0 / (12.0 * h),
            CompanionMethod::Gear5 => 137.0 / (60.0 * h),
        }
    }

    /// Full BDF coefficient set for residual assembly.
    pub fn bdf_coeffs(self, h: f64) -> BdfCoeffs {
        let a = self.alpha(h);
        match self {
            CompanionMethod::BackwardEuler => BdfCoeffs {
                alpha: a,
                history: [-a, 0.0, 0.0, 0.0, 0.0],
                history_len: 1,
            },
            CompanionMethod::Trapezoidal => BdfCoeffs {
                alpha: a,
                history: [-a, 0.0, 0.0, 0.0, 0.0],
                history_len: 1,
            },
            CompanionMethod::Gear2 => BdfCoeffs {
                alpha: a,
                history: [-(4.0 / 3.0) * a, (1.0 / 3.0) * a, 0.0, 0.0, 0.0],
                history_len: 2,
            },
            CompanionMethod::Gear3 => BdfCoeffs {
                alpha: a,
                history: [
                    -(18.0 / 11.0) * a,
                    (9.0 / 11.0) * a,
                    -(2.0 / 11.0) * a,
                    0.0,
                    0.0,
                ],
                history_len: 3,
            },
            CompanionMethod::Gear4 => BdfCoeffs {
                alpha: a,
                history: [
                    -(48.0 / 25.0) * a,
                    (36.0 / 25.0) * a,
                    -(16.0 / 25.0) * a,
                    (3.0 / 25.0) * a,
                    0.0,
                ],
                history_len: 4,
            },
            CompanionMethod::Gear5 => BdfCoeffs {
                alpha: a,
                history: [
                    -(300.0 / 137.0) * a,
                    (300.0 / 137.0) * a,
                    -(200.0 / 137.0) * a,
                    (75.0 / 137.0) * a,
                    -(12.0 / 137.0) * a,
                ],
                history_len: 5,
            },
        }
    }
}

/// Build `J = G + alpha*C` into `dest_triplet`.
pub fn assemble_be_jacobian(
    g_triplet: &TripletMatrix,
    c_triplet: &TripletMatrix,
    alpha: f64,
    dest_triplet: &mut TripletMatrix,
) {
    dest_triplet.clear();
    g_triplet
        .entries()
        .for_each(|(r, c, v)| dest_triplet.add(r, c, v));
    c_triplet
        .entries()
        .for_each(|(r, c, v)| dest_triplet.add(r, c, alpha * v));
}

/// Build the Backward Euler residual: F = g(x) + alpha * ( q(x) - q_prev )
pub fn assemble_be_residual(
    residual_g: &DenseVec,
    residual_q: &DenseVec,
    q_prev: &DenseVec,
    alpha: f64,
    dest_residual: &mut DenseVec,
) {
    let n = residual_g.len();
    debug_assert_eq!(residual_q.len(), n);
    debug_assert_eq!(q_prev.len(), n);
    debug_assert_eq!(dest_residual.len(), n);

    let dst = dest_residual.as_mut_slice();
    let rg = residual_g.as_slice();
    let rq = residual_q.as_slice();
    let qp = q_prev.as_slice();

    dst.iter_mut()
        .zip(rg.iter())
        .zip(rq.iter())
        .zip(qp.iter())
        .for_each(|(((d, &g), &q), &qp_v)| {
            *d = g + alpha * (q - qp_v);
        });
}

/// Build the Trapezoidal residual: F = g(x) + (2/h) * ( q(x) - q_prev ) + g_prev
pub fn assemble_trap_residual(
    residual_g: &DenseVec,
    residual_q: &DenseVec,
    q_prev: &DenseVec,
    g_prev: &DenseVec,
    alpha: f64,
    dest_residual: &mut DenseVec,
) {
    let n = residual_g.len();
    debug_assert_eq!(residual_q.len(), n);
    debug_assert_eq!(q_prev.len(), n);
    debug_assert_eq!(g_prev.len(), n);
    debug_assert_eq!(dest_residual.len(), n);

    let dst = dest_residual.as_mut_slice();
    let rg = residual_g.as_slice();
    let rq = residual_q.as_slice();
    let qp = q_prev.as_slice();
    let gp = g_prev.as_slice();

    dst.iter_mut()
        .zip(rg.iter())
        .zip(rq.iter())
        .zip(qp.iter())
        .zip(gp.iter())
        .for_each(|((((d, &g), &q), &qp_v), &gp_v)| {
            // Only add g_prev for reactive (charge-storing) rows.
            // For algebraic constraints (q=0, qp=0), g_prev would corrupt the equation.
            let gp_contrib = if q.abs() > 1e-30 || qp_v.abs() > 1e-30 {
                gp_v
            } else {
                0.0
            };
            *d = g + gp_contrib + alpha * (q - qp_v);
        });
}

/// Build the Gear-2 residual.
pub fn assemble_gear2_residual(
    residual_g: &DenseVec,
    residual_q: &DenseVec,
    q_prev1: &DenseVec,
    q_prev2: &DenseVec,
    alpha: f64,
    dest_residual: &mut DenseVec,
) {
    let n = residual_g.len();
    debug_assert_eq!(residual_q.len(), n);
    debug_assert_eq!(q_prev1.len(), n);
    debug_assert_eq!(q_prev2.len(), n);
    debug_assert_eq!(dest_residual.len(), n);

    let c1 = (4.0 / 3.0) * alpha;
    let c2 = (1.0 / 3.0) * alpha;

    let dst = dest_residual.as_mut_slice();
    let rg = residual_g.as_slice();
    let rq = residual_q.as_slice();
    let qp1 = q_prev1.as_slice();
    let qp2 = q_prev2.as_slice();

    dst.iter_mut()
        .zip(rg.iter())
        .zip(rq.iter())
        .zip(qp1.iter())
        .zip(qp2.iter())
        .for_each(|((((d, &g), &q), &qp1_v), &qp2_v)| {
            *d = g + alpha * q - c1 * qp1_v + c2 * qp2_v;
        });
}

/// Build a general BDF-k residual using pre-computed [`BdfCoeffs`].
pub fn assemble_bdfk_residual(
    residual_g: &DenseVec,
    residual_q: &DenseVec,
    q_history: &[DenseVec],
    coeffs: &BdfCoeffs,
    dest_residual: &mut DenseVec,
) {
    let n = residual_g.len();
    debug_assert_eq!(residual_q.len(), n);
    debug_assert!(q_history.len() >= coeffs.history_len);
    debug_assert_eq!(dest_residual.len(), n);

    let dst = dest_residual.as_mut_slice();
    let rg = residual_g.as_slice();
    let rq = residual_q.as_slice();

    dst.iter_mut()
        .zip(rg.iter())
        .zip(rq.iter())
        .for_each(|((d, &g), &q)| {
            *d = g + coeffs.alpha * q;
        });

    for i in 0..coeffs.history_len {
        let c = coeffs.history[i];
        let qh = q_history[i].as_slice();
        debug_assert_eq!(qh.len(), n);
        dst.iter_mut()
            .zip(qh.iter())
            .for_each(|(d, &qh_v)| *d += c * qh_v);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alpha_be() {
        assert!((CompanionMethod::BackwardEuler.alpha(1e-3) - 1e3).abs() < 1e-12);
        assert!((CompanionMethod::Trapezoidal.alpha(1e-3) - 2e3).abs() < 1e-12);
    }

    #[test]
    fn alpha_gear_orders() {
        let h = 1e-3;
        assert!((CompanionMethod::Gear2.alpha(h) - 3.0 / (2.0 * h)).abs() < 1e-12);
        assert!((CompanionMethod::Gear3.alpha(h) - 11.0 / (6.0 * h)).abs() < 1e-12);
        assert!((CompanionMethod::Gear4.alpha(h) - 25.0 / (12.0 * h)).abs() < 1e-12);
        assert!((CompanionMethod::Gear5.alpha(h) - 137.0 / (60.0 * h)).abs() < 1e-12);
    }

    #[test]
    fn history_depth_correct() {
        assert_eq!(CompanionMethod::BackwardEuler.history_depth(), 1);
        assert_eq!(CompanionMethod::Gear2.history_depth(), 2);
        assert_eq!(CompanionMethod::Gear3.history_depth(), 3);
        assert_eq!(CompanionMethod::Gear4.history_depth(), 4);
        assert_eq!(CompanionMethod::Gear5.history_depth(), 5);
    }

    #[test]
    fn alpha_be_is_one_over_h() {
        for &h in &[1e-9_f64, 1e-6, 1e-3, 1.0] {
            let alpha = CompanionMethod::BackwardEuler.alpha(h);
            assert!((alpha - 1.0 / h).abs() < 1e-12 * alpha, "BE alpha wrong for h={h}");
        }
    }

    #[test]
    fn alpha_trap_is_two_over_h() {
        for &h in &[1e-9_f64, 1e-6, 1e-3, 1.0] {
            let alpha = CompanionMethod::Trapezoidal.alpha(h);
            assert!((alpha - 2.0 / h).abs() < 1e-12 * alpha, "Trap alpha wrong for h={h}");
        }
    }

    #[test]
    fn alpha_strictly_increases_with_order() {
        let h = 1e-6;
        let a_be   = CompanionMethod::BackwardEuler.alpha(h);
        let a_trap = CompanionMethod::Trapezoidal.alpha(h);
        let a_g2   = CompanionMethod::Gear2.alpha(h);
        let a_g3   = CompanionMethod::Gear3.alpha(h);
        let a_g4   = CompanionMethod::Gear4.alpha(h);
        let a_g5   = CompanionMethod::Gear5.alpha(h);
        assert!(a_be < a_trap, "BE < Trap");
        assert!(a_trap > a_g2, "Trap > Gear2 (trap is 2/h, Gear2 is 3/(2h))");
        assert!(a_g2 < a_g3, "Gear2 < Gear3");
        assert!(a_g3 < a_g4, "Gear3 < Gear4");
        assert!(a_g4 < a_g5, "Gear4 < Gear5");
    }

    #[test]
    fn assemble_be_jacobian_adds_scaled_c() {
        // J = G + alpha*C.  Use simple 2x2 matrices.
        let alpha = 1e3_f64;
        let mut g = TripletMatrix::with_capacity(2, 2, 4);
        g.add(0, 0, 1.0);
        g.add(1, 1, 2.0);
        let mut c = TripletMatrix::with_capacity(2, 2, 4);
        c.add(0, 0, 1.0);
        c.add(1, 1, 0.5);

        let mut jac = TripletMatrix::with_capacity(2, 2, 8);
        assemble_be_jacobian(&g, &c, alpha, &mut jac);

        // Convert to dense-ish by summing entries with matching (r,c).
        let sum_at = |r: usize, c_idx: usize| -> f64 {
            jac.entries().filter(|(ri, ci, _)| *ri == r && *ci == c_idx)
               .map(|(_, _, v)| v).sum::<f64>()
        };
        assert!((sum_at(0, 0) - (1.0 + alpha * 1.0)).abs() < 1e-10, "(0,0) wrong");
        assert!((sum_at(1, 1) - (2.0 + alpha * 0.5)).abs() < 1e-10, "(1,1) wrong");
    }

    #[test]
    fn assemble_be_residual_formula() {
        // F = g + alpha*(q - q_prev)
        let alpha = 2000.0;
        let rg  = DenseVec::from_slice(&[1.0, -1.0]);
        let rq  = DenseVec::from_slice(&[3.0,  2.0]);
        let qp  = DenseVec::from_slice(&[1.0,  1.0]);
        let mut dest = DenseVec::zeros(2);
        assemble_be_residual(&rg, &rq, &qp, alpha, &mut dest);
        // F[0] = 1.0 + 2000*(3-1) = 4001
        // F[1] = -1.0 + 2000*(2-1) = 1999
        assert!((dest[0] - 4001.0).abs() < 1e-10, "F[0]={}", dest[0]);
        assert!((dest[1] - 1999.0).abs() < 1e-10, "F[1]={}", dest[1]);
    }

    #[test]
    fn assemble_trap_residual_includes_g_prev() {
        // F = g + g_prev + alpha*(q - q_prev)
        let alpha = 500.0;
        let rg  = DenseVec::from_slice(&[1.0]);
        let rq  = DenseVec::from_slice(&[2.0]);
        let qp  = DenseVec::from_slice(&[1.0]);
        let gp  = DenseVec::from_slice(&[3.0]);
        let mut dest = DenseVec::zeros(1);
        assemble_trap_residual(&rg, &rq, &qp, &gp, alpha, &mut dest);
        // F = 1 + 3 + 500*(2-1) = 504
        assert!((dest[0] - 504.0).abs() < 1e-10, "F={}", dest[0]);
    }

    #[test]
    fn assemble_be_residual_zero_when_q_equals_q_prev() {
        // When q == q_prev, F = g.
        let alpha = 1e9;
        let rg = DenseVec::from_slice(&[0.5, -0.5]);
        let rq = DenseVec::from_slice(&[1.0,  2.0]);
        let qp = rq.clone();
        let mut dest = DenseVec::zeros(2);
        assemble_be_residual(&rg, &rq, &qp, alpha, &mut dest);
        assert!((dest[0] - 0.5).abs() < 1e-10);
        assert!((dest[1] + 0.5).abs() < 1e-10);
    }

    #[test]
    fn assemble_gear2_residual_formula() {
        // F = g + alpha*q - (4/3)*alpha*q1 + (1/3)*alpha*q2
        let h = 1e-3;
        let alpha = CompanionMethod::Gear2.alpha(h);
        let c1 = (4.0 / 3.0) * alpha;
        let c2 = (1.0 / 3.0) * alpha;

        let rg  = DenseVec::from_slice(&[0.0]);
        let rq  = DenseVec::from_slice(&[3.0]);
        let qp1 = DenseVec::from_slice(&[2.0]);
        let qp2 = DenseVec::from_slice(&[1.0]);
        let mut dest = DenseVec::zeros(1);
        assemble_gear2_residual(&rg, &rq, &qp1, &qp2, alpha, &mut dest);
        let expected = alpha * 3.0 - c1 * 2.0 + c2 * 1.0;
        assert!((dest[0] - expected).abs() < 1e-8, "Gear2 residual={} expected={}", dest[0], expected);
    }

    #[test]
    fn bdf_coeffs_history_length_matches_depth() {
        for method in [
            CompanionMethod::BackwardEuler,
            CompanionMethod::Trapezoidal,
            CompanionMethod::Gear2,
            CompanionMethod::Gear3,
            CompanionMethod::Gear4,
            CompanionMethod::Gear5,
        ] {
            let coeffs = method.bdf_coeffs(1e-6);
            assert_eq!(coeffs.history_len, method.history_depth(),
                "history_len mismatch for {method:?}");
        }
    }

    #[test]
    fn assemble_bdfk_residual_matches_be() {
        // For BackwardEuler, bdfk_residual must match assemble_be_residual.
        let h = 1e-6;
        let method = CompanionMethod::BackwardEuler;
        let alpha = method.alpha(h);
        let coeffs = method.bdf_coeffs(h);

        let rg = DenseVec::from_slice(&[2.0, -1.0]);
        let rq = DenseVec::from_slice(&[3.0,  0.5]);
        let qp = DenseVec::from_slice(&[1.0,  1.0]);

        let mut dest_be  = DenseVec::zeros(2);
        let mut dest_bdfk = DenseVec::zeros(2);

        assemble_be_residual(&rg, &rq, &qp, alpha, &mut dest_be);
        assemble_bdfk_residual(&rg, &rq, &[qp.clone()], &coeffs, &mut dest_bdfk);

        for i in 0..2 {
            assert!((dest_be[i] - dest_bdfk[i]).abs() < 1e-10,
                "dim {i}: BE={} bdfk={}", dest_be[i], dest_bdfk[i]);
        }
    }
}
