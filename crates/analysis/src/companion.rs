//! Companion model helpers for transient analysis.
//!
//! Implements Backward Euler (and a stub for Trapezoidal) discretization
//! of the reactive contributions.  See CLAUDE.md for the data layout
//! conventions used here (flat preallocated buffers, no per-step allocs).
//!
//! For Backward Euler at timestep `h`, the discretized residual is
//!
//!   F(x_{n+1}) = g(x_{n+1}) + (1/h) * ( q(x_{n+1}) - q(x_n) ) - sources(t_{n+1})
//!
//! and its Jacobian is
//!
//!   J = G + (1/h) * C
//!
//! Trapezoidal uses (2/h) instead of (1/h) and additionally subtracts the
//! contribution from the previous step's resistive residual.
//!
//! ## BDF coefficient tables
//!
//! BDF-k approximates x'_n as a linear combination of the k+1 most recent
//! solution points.  The standard form is:
//!
//!   sum_{j=0}^{k} alpha_j * x_{n-j} = h * beta_0 * f_n
//!
//! For residual assembly we rearrange to:
//!
//!   F = g(x_n) + (alpha_0 / (h * beta_0)) * q(x_n)
//!       - sum_{j=1}^{k} (alpha_j / (h * beta_0)) * q(x_{n-j})
//!
//! The `alpha` field returned by [`CompanionMethod::alpha`] equals
//! `alpha_0 / (h * beta_0)`, i.e. the coefficient on the current q.
//! The `history_coeffs` field gives the coefficients applied to each
//! historical q slot, in order from newest (n-1) to oldest (n-k).

use bigospice_linalg::{DenseVec, TripletMatrix};

/// Time integration method recognised by the companion solver.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompanionMethod {
    BackwardEuler,
    Trapezoidal,
    /// 2nd-order Gear BDF.  Requires two prior steps of history; the
    /// first step is bootstrapped with Backward Euler.
    Gear2,
    /// 3rd-order Gear BDF.  Requires three prior steps; bootstrapped with
    /// Gear-2 until enough history has accumulated.
    Gear3,
    /// 4th-order Gear BDF.  Requires four prior steps.
    Gear4,
    /// 5th-order Gear BDF.  Requires five prior steps.
    Gear5,
}

/// BDF-k history coefficients: `(alpha_current, [alpha_prev1, alpha_prev2, …])`.
///
/// Each coefficient is scaled by `1 / (h * beta_0)`, so the caller simply
/// multiplies by the corresponding q vector.  The array has exactly `k-1`
/// entries for BDF-k (k ≥ 2) and 0 entries for BE.
///
/// Values derived from the standard BDF coefficient tables (Gear 1971):
///
/// | Order | alpha_0 / (h*beta_0) | history coefficients (newest → oldest)          |
/// |-------|----------------------|-------------------------------------------------|
/// | 1 (BE)| 1/h                  | none                                            |
/// | 2     | 3/(2h)               | -4/3·α, +1/3·α                                 |
/// | 3     | 11/(6h)              | -18/11·α, +9/11·α, -2/11·α                     |
/// | 4     | 25/(12h)             | -48/25·α, +36/25·α, -16/25·α, +3/25·α         |
/// | 5     | 137/(60h)            | -300/137·α, +300/137·α, -200/137·α, +75/137·α, -12/137·α |
pub struct BdfCoeffs {
    /// Coefficient on the current-step q (= alpha_0 / (h*beta_0) * h, i.e. alpha).
    pub alpha: f64,
    /// Coefficients for historical q slots, newest first.
    /// Length = integration order - 1.
    pub history: [f64; 5],
    /// Number of valid history slots (= integration order - 1).
    pub history_len: usize,
}

impl CompanionMethod {
    /// Number of historical solution slots required (0 for BE, 1 for Trap,
    /// k-1 for BDF-k).
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
    ///
    /// For Gear-2:  x'_n ≈ (3x_n - 4x_{n-1} + x_{n-2}) / (2h)
    /// so alpha = 3/(2h).
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
    ///
    /// `alpha` is the coefficient on the current-step q.
    /// `history[i]` is the coefficient on the (i+1)-steps-ago q, with
    /// *negative* values meaning it is subtracted in the residual.
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
            // Gear-2: F = g + (3/2h)*q_n - (4/3)*(3/2h)*q_{n-1} + (1/3)*(3/2h)*q_{n-2}
            //           = g + α*q_n - (4/3)α*q_{n-1} + (1/3)α*q_{n-2}
            CompanionMethod::Gear2 => BdfCoeffs {
                alpha: a,
                history: [-(4.0 / 3.0) * a, (1.0 / 3.0) * a, 0.0, 0.0, 0.0],
                history_len: 2,
            },
            // Gear-3: x'_n ≈ (11x_n - 18x_{n-1} + 9x_{n-2} - 2x_{n-3}) / (6h)
            // alpha = 11/(6h); h_coeffs: -18/11·α, +9/11·α, -2/11·α
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
            // Gear-4: alpha = 25/(12h)
            // h_coeffs: -48/25·α, +36/25·α, -16/25·α, +3/25·α
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
            // Gear-5: alpha = 137/(60h)
            // h_coeffs: -300/137·α, +300/137·α, -200/137·α, +75/137·α, -12/137·α
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

/// Build `J = G + alpha*C` into `dest_triplet`, given `g_triplet` and
/// `c_triplet` already filled in by `stamp_circuit_gc_into`.
///
/// `dest_triplet` is cleared first.
pub fn assemble_be_jacobian(
    g_triplet: &TripletMatrix,
    c_triplet: &TripletMatrix,
    alpha: f64,
    dest_triplet: &mut TripletMatrix,
) {
    dest_triplet.clear();
    g_triplet.entries().for_each(|(r, c, v)| dest_triplet.add(r, c, v));
    c_triplet.entries().for_each(|(r, c, v)| dest_triplet.add(r, c, alpha * v));
}

/// Build the Backward Euler residual into `dest_residual`:
///   F = g(x) + alpha * ( q(x) - q_prev )
///
/// `residual_g` already includes source RHS contributions, so the result
/// is the full Newton residual to drive to zero.
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

/// Build the Trapezoidal residual into `dest_residual`:
///   F = g(x) + (2/h) * ( q(x) - q_prev ) + g_prev
///
/// The Trap rule averages the resistive contributions at t_n and t_{n+1}:
///   F = g(x_{n+1}) + g(x_n) + (2/h) * ( q(x_{n+1}) - q(x_n) )
///
/// Here `alpha = 2/h` and `g_prev = g(x_n)` (resistive residual at the
/// previously accepted timestep).
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
            *d = g + gp_v + alpha * (q - qp_v);
        });
}

/// Build the Gear-2 residual into `dest_residual`:
///   F = g(x_n) + (3C/2h) * q(x_n) - (4C/2h)*q_n1 + (C/2h)*q_n2
///
/// where `q_prev1` = q at step n-1, `q_prev2` = q at step n-2.
/// `alpha = 3/(2h)`.
///
/// During bootstrap (first step only), the caller falls back to
/// [`assemble_be_residual`] so this function is never reached with
/// uninitialized history.
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

    // alpha = 3/(2h)
    // Gear-2: x'_n ≈ (3x_n - 4x_{n-1} + x_{n-2}) / (2h)
    // F = g + alpha*q_n - (4/3)*alpha*q_{n-1} + (1/3)*alpha*q_{n-2}
    let c1 = (4.0 / 3.0) * alpha; // coefficient for q_prev1
    let c2 = (1.0 / 3.0) * alpha; // coefficient for q_prev2

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

/// Build a general BDF-k residual into `dest_residual` using pre-computed
/// [`BdfCoeffs`].
///
/// The residual is:
///
///   F = g(x_n) + alpha * q(x_n)
///       + coeffs.history[0] * q_{n-1}
///       + coeffs.history[1] * q_{n-2}
///       + …
///
/// `q_history` must contain at least `coeffs.history_len` entries, ordered
/// newest-first (index 0 = step n-1, index 1 = step n-2, …).
///
/// For BDF-1 (BackwardEuler) pass a single-element `q_history` containing
/// q_{n-1}; the coefficient is `history[0] = -alpha`, so the formula
/// reduces to the standard BE residual.
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

    // Initialise with g + alpha*q_n.
    dst.iter_mut()
        .zip(rg.iter())
        .zip(rq.iter())
        .for_each(|((d, &g), &q)| {
            *d = g + coeffs.alpha * q;
        });

    // Accumulate history contributions.
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
        // Gear-2: 3/(2h)
        assert!((CompanionMethod::Gear2.alpha(h) - 3.0 / (2.0 * h)).abs() < 1e-12);
        // Gear-3: 11/(6h)
        assert!((CompanionMethod::Gear3.alpha(h) - 11.0 / (6.0 * h)).abs() < 1e-12);
        // Gear-4: 25/(12h)
        assert!((CompanionMethod::Gear4.alpha(h) - 25.0 / (12.0 * h)).abs() < 1e-12);
        // Gear-5: 137/(60h)
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
    fn bdf_coeffs_gear2_matches_legacy() {
        // bdf_coeffs for Gear2 must reproduce the same history coefficients
        // as the hard-coded assemble_gear2_residual path.
        let h = 2e-3;
        let coeffs = CompanionMethod::Gear2.bdf_coeffs(h);
        let alpha = 3.0 / (2.0 * h);
        assert!((coeffs.alpha - alpha).abs() < 1e-12);
        assert!((coeffs.history[0] - (-(4.0 / 3.0) * alpha)).abs() < 1e-12);
        assert!((coeffs.history[1] - ((1.0 / 3.0) * alpha)).abs() < 1e-12);
        assert_eq!(coeffs.history_len, 2);
    }

    #[test]
    fn bdfk_residual_matches_be() {
        // assemble_bdfk_residual with BE coeffs must equal assemble_be_residual.
        let h = 1e-3;
        let rg = DenseVec::from_slice(&[0.5, 1.0]);
        let rq = DenseVec::from_slice(&[2.0, 3.0]);
        let qp = DenseVec::from_slice(&[1.0, 1.5]);
        let mut dst_be = DenseVec::zeros(2);
        let mut dst_bdfk = DenseVec::zeros(2);
        let alpha = CompanionMethod::BackwardEuler.alpha(h);
        assemble_be_residual(&rg, &rq, &qp, alpha, &mut dst_be);
        let coeffs = CompanionMethod::BackwardEuler.bdf_coeffs(h);
        assemble_bdfk_residual(&rg, &rq, &[qp.clone()], &coeffs, &mut dst_bdfk);
        for i in 0..2 {
            assert!((dst_be[i] - dst_bdfk[i]).abs() < 1e-12,
                "index {i}: BE={} BDFk={}", dst_be[i], dst_bdfk[i]);
        }
    }

    #[test]
    fn bdfk_residual_gear3_sanity() {
        // For constant q (q_n = q_{n-1} = q_{n-2} = q_{n-3} = C), the
        // Gear-3 residual should produce: g + (11/6h)*C*(1 - 18/11 + 9/11 - 2/11)
        // = g + (11/6h)*C * (11 - 18 + 9 - 2)/11 = g + (11/6h)*C * 0/11 = g.
        let h = 1e-4;
        let q_val = 3.5_f64;
        let g_val = 0.7_f64;
        let rg = DenseVec::from_slice(&[g_val]);
        let rq = DenseVec::from_slice(&[q_val]);
        let qp = DenseVec::from_slice(&[q_val]);
        let coeffs = CompanionMethod::Gear3.bdf_coeffs(h);
        let history = vec![qp.clone(), qp.clone(), qp.clone()];
        let mut dst = DenseVec::zeros(1);
        assemble_bdfk_residual(&rg, &rq, &history, &coeffs, &mut dst);
        // Should be approximately g (BDF-k is consistent with constant solution).
        assert!((dst[0] - g_val).abs() < 1e-6,
            "Gear-3 constant-q: expected {g_val}, got {}", dst[0]);
    }

    #[test]
    fn bdfk_residual_gear5_sanity() {
        // Same constant-q consistency check for Gear-5.
        let h = 1e-4;
        let q_val = 1.0_f64;
        let g_val = 2.0_f64;
        let rg = DenseVec::from_slice(&[g_val]);
        let rq = DenseVec::from_slice(&[q_val]);
        let qp = DenseVec::from_slice(&[q_val]);
        let coeffs = CompanionMethod::Gear5.bdf_coeffs(h);
        let history = vec![qp.clone(), qp.clone(), qp.clone(), qp.clone(), qp.clone()];
        let mut dst = DenseVec::zeros(1);
        assemble_bdfk_residual(&rg, &rq, &history, &coeffs, &mut dst);
        assert!((dst[0] - g_val).abs() < 1e-6,
            "Gear-5 constant-q: expected {g_val}, got {}", dst[0]);
    }

    #[test]
    fn assemble_jacobian_combines() {
        let mut g = TripletMatrix::new(2, 2);
        g.add(0, 0, 1.0);
        g.add(1, 1, 2.0);
        let mut c = TripletMatrix::new(2, 2);
        c.add(0, 0, 4.0);
        let mut dst = TripletMatrix::new(2, 2);
        assemble_be_jacobian(&g, &c, 0.5, &mut dst);
        let csc = dst.to_csc();
        assert!((csc.get(0, 0).unwrap() - 3.0).abs() < 1e-12);
        assert!((csc.get(1, 1).unwrap() - 2.0).abs() < 1e-12);
    }

    #[test]
    fn assemble_residual_correct() {
        let rg = DenseVec::from_slice(&[0.5, 1.0]);
        let rq = DenseVec::from_slice(&[2.0, 3.0]);
        let qp = DenseVec::from_slice(&[1.0, 1.5]);
        let mut dst = DenseVec::zeros(2);
        assemble_be_residual(&rg, &rq, &qp, 10.0, &mut dst);
        // 0.5 + 10*(2 - 1) = 10.5; 1.0 + 10*(3 - 1.5) = 16.0
        assert!((dst[0] - 10.5).abs() < 1e-12);
        assert!((dst[1] - 16.0).abs() < 1e-12);
    }
}
