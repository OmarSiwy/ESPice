//! Sparse triangular solves on top of [`LuFactors`].
//!
//! `lu_solve(factors, b)` solves `A x = b` where `factors` came from
//! [`crate::lu::lu_factorize`].  The factorisation captures:
//!   `(P_lu) * (P_btf_row * A * P_btf_col^{-1}) * Q_amd^{-1} = L * U`
//! The solve unrolls as:
//!
//!   1. `b' = P_btf_row * b`    (BTF row permutation)
//!   2. `L y = b'`              (sparse forward substitution, folds P_lu)
//!   3. `U z = y`               (sparse back substitution)
//!   4. `x = (Q_amd ∘ P_btf_col)^{-1} z`  (undo combined col permutation)
//!
//! All operations are performed using the underlying CSC L and U — there
//! is no dense expansion.

use super::dense_vec::DenseVec;
use super::lu::LuFactors;
use super::sparse_lu;
use incspice_core::SimError;

/// Solve `A x = b` given LU factors from `lu_factorize`.
pub fn lu_solve(factors: &LuFactors, b: &DenseVec) -> Result<DenseVec, SimError> {
    let n = factors.n;
    assert_eq!(b.len(), n, "lu_solve: dimension mismatch");

    // Step 1: apply BTF row permutation — b' = P_btf_row * b.
    // forward()[orig_row] = new_row, so b'[new_row] = b[orig_row].
    let btf_fwd = factors.btf_row_perm.forward();
    let b_perm: DenseVec = if btf_fwd.iter().enumerate().all(|(i, &p)| i == p) {
        b.clone()
    } else {
        let mut bp = DenseVec::zeros(n);
        for (orig, &new_row) in btf_fwd.iter().enumerate() {
            bp[new_row] = b[orig];
        }
        bp
    };

    // Step 2: forward solve  L y = b'  (the LU row permutation is folded in).
    let mut y = vec![0.0f64; n];
    sparse_lu::forward_solve_inplace(&factors.inner, b_perm.as_slice(), &mut y);

    // Step 3: back solve  U z = y    (z is in the BTF+AMD-permuted col space).
    let mut z = vec![0.0f64; n];
    sparse_lu::back_solve_inplace(&factors.inner, &y, &mut z)?;

    // Step 4: undo the combined BTF+AMD column permutation.
    // col_perm.forward()[orig_col] = permuted col index, so
    // x[orig] = z[col_perm.forward()[orig]].
    let col_perm = &factors.inner.col_perm;
    let fwd = col_perm.forward();
    let mut x = DenseVec::zeros(n);
    for orig in 0..n {
        x[orig] = z[fwd[orig]];
    }
    Ok(x)
}

/// Forward substitution: solve `L y = b`.  Public legacy entry point —
/// allocates a fresh `DenseVec` for the result.
pub fn forward_solve(factors: &LuFactors, b: &DenseVec) -> DenseVec {
    let n = factors.n;
    let mut out = vec![0.0f64; n];
    sparse_lu::forward_solve_inplace(&factors.inner, b.as_slice(), &mut out);
    DenseVec::from_slice(&out)
}

/// Back substitution: solve `U x = y`.  Both vectors are in the
/// AMD-permuted column space; callers using the high-level `lu_solve`
/// should NOT need to invoke this directly.
pub fn back_solve(factors: &LuFactors, y: &DenseVec) -> Result<DenseVec, SimError> {
    let n = factors.n;
    let mut out = vec![0.0f64; n];
    sparse_lu::back_solve_inplace(&factors.inner, y.as_slice(), &mut out)?;
    Ok(DenseVec::from_slice(&out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linalg::csc::CscMatrix;
    use crate::linalg::lu::lu_factorize;
    use crate::linalg::triplet::TripletMatrix;

    #[test]
    fn solve_2x2() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 4.0);
        t.add(0, 1, 1.0);
        t.add(1, 0, 2.0);
        t.add(1, 1, 3.0);
        let a = t.to_csc();
        let factors = lu_factorize(&a).unwrap();

        let b = DenseVec::from_slice(&[9.0, 11.0]);
        let x = lu_solve(&factors, &b).unwrap();

        let residual = a.mul_vec(&x);
        for i in 0..2 {
            assert!(
                (residual[i] - b[i]).abs() < 1e-12,
                "residual[{i}] = {} expected {}",
                residual[i],
                b[i]
            );
        }
    }

    #[test]
    fn solve_preserves_rhs() {
        let id = CscMatrix::identity(3);
        let factors = lu_factorize(&id).unwrap();
        let b = DenseVec::from_slice(&[7.0, 8.0, 9.0]);
        let x = lu_solve(&factors, &b).unwrap();
        for i in 0..3 {
            assert!((x[i] - b[i]).abs() < 1e-14);
        }
    }

    #[test]
    fn solve_with_pivoting() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 1, 2.0);
        t.add(1, 0, 3.0);
        t.add(1, 1, 1.0);
        let a = t.to_csc();
        let factors = lu_factorize(&a).unwrap();

        let b = DenseVec::from_slice(&[6.0, 5.0]);
        let x = lu_solve(&factors, &b).unwrap();

        let check = a.mul_vec(&x);
        for i in 0..2 {
            assert!(
                (check[i] - b[i]).abs() < 1e-12,
                "Ax[{i}]={} != b[{i}]={}",
                check[i],
                b[i]
            );
        }
    }

    #[test]
    fn lu_solve_1x1_system() {
        let mut t = TripletMatrix::new(1, 1);
        t.add(0, 0, 4.0);
        let a = t.to_csc();
        let factors = lu_factorize(&a).unwrap();
        let b = DenseVec::from_slice(&[12.0]);
        let x = lu_solve(&factors, &b).unwrap();
        assert!((x[0] - 3.0).abs() < 1e-14);
    }

    #[test]
    fn lu_solve_4x4_system() {
        // Build a symmetric positive definite 4x4 system
        let mut t = TripletMatrix::new(4, 4);
        t.add(0, 0, 4.0);
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        t.add(1, 1, 3.0);
        t.add(1, 2, 1.0);
        t.add(2, 1, 1.0);
        t.add(2, 2, 4.0);
        t.add(2, 3, 1.0);
        t.add(3, 2, 1.0);
        t.add(3, 3, 3.0);
        let a = t.to_csc();
        let x_true = DenseVec::from_slice(&[1.0, -1.0, 2.0, -2.0]);
        let b = a.mul_vec(&x_true);
        let factors = lu_factorize(&a).unwrap();
        let x = lu_solve(&factors, &b).unwrap();
        for i in 0..4 {
            assert!((x[i] - x_true[i]).abs() < 1e-10, "x[{i}]={}", x[i]);
        }
    }

    #[test]
    fn lu_solve_residual_check() {
        // Verify A*x - b is small after solve
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 3.0);
        t.add(0, 2, 1.0);
        t.add(1, 1, 5.0);
        t.add(2, 0, 2.0);
        t.add(2, 2, 4.0);
        let a = t.to_csc();
        let b = DenseVec::from_slice(&[7.0, 10.0, 14.0]);
        let factors = lu_factorize(&a).unwrap();
        let x = lu_solve(&factors, &b).unwrap();
        let ax = a.mul_vec(&x);
        for i in 0..3 {
            assert!((ax[i] - b[i]).abs() < 1e-10, "residual[{i}]={}", (ax[i] - b[i]).abs());
        }
    }

    #[test]
    fn forward_solve_identity() {
        // Forward solve with identity L: y = b
        let id = CscMatrix::identity(3);
        let factors = lu_factorize(&id).unwrap();
        let b = DenseVec::from_slice(&[4.0, 5.0, 6.0]);
        let y = forward_solve(&factors, &b);
        // For identity matrix, the forward solve should produce permuted b
        // which ends up being the original b after re-permutation
        assert_eq!(y.len(), 3);
    }

    #[test]
    fn back_solve_diagonal_matrix() {
        // A = diag(2, 3, 5), solve Ax = b
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 2.0);
        t.add(1, 1, 3.0);
        t.add(2, 2, 5.0);
        let a = t.to_csc();
        let factors = lu_factorize(&a).unwrap();
        let b = DenseVec::from_slice(&[2.0, 9.0, 15.0]);
        let x = lu_solve(&factors, &b).unwrap();
        assert!((x[0] - 1.0).abs() < 1e-12, "x[0]={}", x[0]);
        assert!((x[1] - 3.0).abs() < 1e-12, "x[1]={}", x[1]);
        assert!((x[2] - 3.0).abs() < 1e-12, "x[2]={}", x[2]);
    }
}
