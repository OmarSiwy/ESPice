//! Phase 5.4 — Woodbury rank-k incremental LU update.
//!
//! Given an existing dense LU (or just a black-box solver function for
//! `J_old · x = b`), this module applies the Sherman-Morrison-Woodbury
//! identity to solve `(J_old + U·V^T) · x = b` without refactorising.
//!
//! ## The identity
//!
//! ```text
//!   (J + U V^T)^{-1} = J^{-1}
//!                    - J^{-1} U (I_k + V^T J^{-1} U)^{-1} V^T J^{-1}
//! ```
//!
//! - `J` is `n × n`.
//! - `U`, `V` are `n × k` (with `k ≪ n`).
//! - The new "small" matrix `I_k + V^T J^{-1} U` is `k × k`, so a fresh
//!   factorisation of *that* is `O(k^3)` instead of `O(n^3)`.
//!
//! Cost: `2k` solves of `J·z = u_i / v_i`, plus an `O(k^3)` dense solve.
//! For `k ≪ √n` this is dramatically cheaper than a full refactor.
//!
//! ## Cutover
//!
//! When `k > √n` we punt: re-factoring is asymptotically cheaper.  The
//! decision is made by [`should_use_woodbury`].
//!
//! ## Storage
//!
//! Updates are accumulated as flat `Vec<f64>` SoA blocks:
//!
//! - `u: Vec<f64>` of length `n*k`, column-major (column `j` lives at
//!   `j*n .. (j+1)*n`).
//! - `v: Vec<f64>` same shape.
//!
//! ## Status
//!
//! This is the *math* layer.  Wiring it into `crates/solver/`'s sparse LU is
//! deferred to the solver agent — they'll provide a closure that solves
//! against `J_old`, and `WoodburyUpdater::solve` does the rest.

/// Should we apply Woodbury for `k` rank-1 changes in an `n×n` system?
#[inline]
pub fn should_use_woodbury(n: usize, k: usize) -> bool {
    if k == 0 || n == 0 {
        return false;
    }
    let sqrt_n = (n as f64).sqrt() as usize;
    k <= sqrt_n.max(1)
}

/// Accumulator for an `n × k` low-rank update `U V^T`.
///
/// Columns are appended one at a time via [`push_rank1`].  When the caller
/// is ready to solve, [`solve`] consumes a base solver closure and returns
/// the corrected solution.
#[derive(Debug, Clone)]
pub struct WoodburyUpdate {
    /// System dimension.
    pub n: usize,
    /// Current rank (number of `(u, v)` columns appended).
    pub k: usize,
    /// `n × k` column-major buffer.
    u: Vec<f64>,
    /// `n × k` column-major buffer.
    v: Vec<f64>,
}

impl WoodburyUpdate {
    pub fn new(n: usize) -> Self {
        Self {
            n,
            k: 0,
            u: Vec::new(),
            v: Vec::new(),
        }
    }

    pub fn rank(&self) -> usize {
        self.k
    }

    pub fn dim(&self) -> usize {
        self.n
    }

    /// Append one rank-1 outer product `u · v^T` to the accumulated update.
    pub fn push_rank1(&mut self, u_col: &[f64], v_col: &[f64]) {
        debug_assert_eq!(u_col.len(), self.n);
        debug_assert_eq!(v_col.len(), self.n);
        self.u.extend_from_slice(u_col);
        self.v.extend_from_slice(v_col);
        self.k += 1;
    }

    /// Reset to zero rank, retaining capacity.
    pub fn clear(&mut self) {
        self.u.clear();
        self.v.clear();
        self.k = 0;
    }

    /// Solve `(J_old + U V^T) · x = b` using Woodbury.
    ///
    /// `solve_base(rhs, out)` is expected to compute `J_old^{-1} · rhs` and
    /// store the result in `out`.  All temporary buffers are heap-allocated
    /// here for clarity; a hot-loop variant could reuse scratch.
    ///
    /// Returns `Err` if the inner `k×k` system is singular.
    pub fn solve<F>(&self, b: &[f64], out: &mut [f64], mut solve_base: F) -> Result<(), &'static str>
    where
        F: FnMut(&[f64], &mut [f64]),
    {
        let n = self.n;
        let k = self.k;
        if b.len() != n || out.len() != n {
            return Err("woodbury: dimension mismatch");
        }

        // Step 1: y = J^{-1} b
        let mut y = vec![0.0; n];
        solve_base(b, &mut y);

        // Trivial path — no updates queued.
        if k == 0 {
            out.copy_from_slice(&y);
            return Ok(());
        }

        // Step 2: Z = J^{-1} U  (n × k, column-major)
        let mut z = vec![0.0; n * k];
        let mut col_buf = vec![0.0; n];
        for j in 0..k {
            let u_col = &self.u[j * n..(j + 1) * n];
            solve_base(u_col, &mut col_buf);
            z[j * n..(j + 1) * n].copy_from_slice(&col_buf);
        }

        // Step 3: M = I_k + V^T Z   (k × k, row-major)
        let mut m = vec![0.0; k * k];
        for i in 0..k {
            let v_i = &self.v[i * n..(i + 1) * n];
            for j in 0..k {
                let z_j = &z[j * n..(j + 1) * n];
                let mut s = 0.0;
                for p in 0..n {
                    s += v_i[p] * z_j[p];
                }
                m[i * k + j] = s;
            }
            m[i * k + i] += 1.0;
        }

        // Step 4: rhs_k = V^T y   (length k)
        let mut rhs_k = vec![0.0; k];
        for i in 0..k {
            let v_i = &self.v[i * n..(i + 1) * n];
            let mut s = 0.0;
            for p in 0..n {
                s += v_i[p] * y[p];
            }
            rhs_k[i] = s;
        }

        // Step 5: solve M · w = rhs_k via Gaussian elimination on the k×k.
        let w = gauss_solve_dense(&mut m, &mut rhs_k, k)?;

        // Step 6: x = y - Z · w
        for p in 0..n {
            let mut s = y[p];
            for j in 0..k {
                s -= z[j * n + p] * w[j];
            }
            out[p] = s;
        }
        Ok(())
    }
}

/// Tiny dense Gaussian eliminator with partial pivoting for the inner
/// `k × k` Woodbury system.  `k` is small (typically 1–10) so a textbook
/// implementation is fine.
fn gauss_solve_dense(m: &mut [f64], rhs: &mut [f64], k: usize) -> Result<Vec<f64>, &'static str> {
    if k == 0 {
        return Ok(Vec::new());
    }
    // Forward elimination with partial pivoting.
    for i in 0..k {
        // Find pivot row.
        let mut piv_row = i;
        let mut piv_val = m[i * k + i].abs();
        for r in (i + 1)..k {
            let v = m[r * k + i].abs();
            if v > piv_val {
                piv_val = v;
                piv_row = r;
            }
        }
        if piv_val < 1e-18 {
            return Err("woodbury: inner k×k system singular");
        }
        if piv_row != i {
            // Swap rows i and piv_row in m and rhs.
            for c in 0..k {
                m.swap(i * k + c, piv_row * k + c);
            }
            rhs.swap(i, piv_row);
        }
        let pv = m[i * k + i];
        for r in (i + 1)..k {
            let f = m[r * k + i] / pv;
            for c in i..k {
                m[r * k + c] -= f * m[i * k + c];
            }
            rhs[r] -= f * rhs[i];
        }
    }
    // Back substitution.
    let mut w = vec![0.0; k];
    for i in (0..k).rev() {
        let mut s = rhs[i];
        for c in (i + 1)..k {
            s -= m[i * k + c] * w[c];
        }
        w[i] = s / m[i * k + i];
    }
    Ok(w)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Solve `A x = b` for a 3×3 dense `A` by direct inverse, used as the
    /// base solver in the round-trip test below.
    fn dense_inverse_solve(a: &[f64], b: &[f64], out: &mut [f64]) {
        // Cramer's rule for a 3×3.
        let det = a[0] * (a[4] * a[8] - a[5] * a[7])
            - a[1] * (a[3] * a[8] - a[5] * a[6])
            + a[2] * (a[3] * a[7] - a[4] * a[6]);
        let inv = [
            (a[4] * a[8] - a[5] * a[7]) / det,
            -(a[1] * a[8] - a[2] * a[7]) / det,
            (a[1] * a[5] - a[2] * a[4]) / det,
            -(a[3] * a[8] - a[5] * a[6]) / det,
            (a[0] * a[8] - a[2] * a[6]) / det,
            -(a[0] * a[5] - a[2] * a[3]) / det,
            (a[3] * a[7] - a[4] * a[6]) / det,
            -(a[0] * a[7] - a[1] * a[6]) / det,
            (a[0] * a[4] - a[1] * a[3]) / det,
        ];
        for r in 0..3 {
            let mut s = 0.0;
            for c in 0..3 {
                s += inv[r * 3 + c] * b[c];
            }
            out[r] = s;
        }
    }

    #[test]
    fn cutover_threshold() {
        // n=100 → sqrt = 10, so k=5 should use Woodbury, k=20 should not.
        assert!(should_use_woodbury(100, 5));
        assert!(!should_use_woodbury(100, 20));
        assert!(!should_use_woodbury(100, 0));
    }

    #[test]
    fn rank1_round_trip() {
        // J_old (3×3, well-conditioned).
        let j_old = [
            4.0, 1.0, 0.0,
            1.0, 3.0, 1.0,
            0.0, 1.0, 2.0,
        ];
        // Rank-1 update: u = (1,0,0), v = (0,1,0)  ⇒  U V^T has a single 1
        // at position (0,1).
        let u_col = [1.0, 0.0, 0.0];
        let v_col = [0.0, 1.0, 0.0];
        let mut j_new = j_old;
        for i in 0..3 {
            for j in 0..3 {
                j_new[i * 3 + j] += u_col[i] * v_col[j];
            }
        }

        let b = [1.0, 2.0, 3.0];

        // Reference solution from the *new* matrix directly.
        let mut x_ref = [0.0; 3];
        dense_inverse_solve(&j_new, &b, &mut x_ref);

        // Woodbury solution using only the *old* matrix as base.
        let mut wood = WoodburyUpdate::new(3);
        wood.push_rank1(&u_col, &v_col);
        let mut x_wood = [0.0; 3];
        wood.solve(&b, &mut x_wood, |rhs, out| {
            dense_inverse_solve(&j_old, rhs, out);
        })
        .unwrap();

        for i in 0..3 {
            let diff = (x_ref[i] - x_wood[i]).abs();
            assert!(diff < 1e-12, "x_ref[{i}]={} x_wood[{i}]={} diff={diff}", x_ref[i], x_wood[i]);
        }
    }

    #[test]
    fn rank2_round_trip() {
        let j_old = [
            5.0, 1.0, 0.0,
            1.0, 4.0, 1.0,
            0.0, 1.0, 3.0,
        ];
        let mut wood = WoodburyUpdate::new(3);
        let u1 = [0.5, 0.0, 0.0];
        let v1 = [0.0, 0.0, 0.7];
        let u2 = [0.0, 0.3, 0.0];
        let v2 = [0.6, 0.0, 0.0];
        wood.push_rank1(&u1, &v1);
        wood.push_rank1(&u2, &v2);

        let mut j_new = j_old;
        for i in 0..3 {
            for j in 0..3 {
                j_new[i * 3 + j] += u1[i] * v1[j] + u2[i] * v2[j];
            }
        }

        let b = [3.0, 2.0, 1.0];
        let mut x_ref = [0.0; 3];
        dense_inverse_solve(&j_new, &b, &mut x_ref);

        let mut x_wood = [0.0; 3];
        wood.solve(&b, &mut x_wood, |rhs, out| {
            dense_inverse_solve(&j_old, rhs, out);
        })
        .unwrap();

        for i in 0..3 {
            assert!((x_ref[i] - x_wood[i]).abs() < 1e-12);
        }
    }
}
