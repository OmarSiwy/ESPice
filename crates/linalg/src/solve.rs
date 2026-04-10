//! Sparse triangular solves on top of [`LuFactors`].
//!
//! `lu_solve(factors, b)` solves `A x = b` where `factors` came from
//! [`crate::lu::lu_factorize`].  The factorisation captures `P A Q = L U`
//! where `P` is the row permutation chosen by partial pivoting and `Q`
//! is the AMD column permutation.  The solve unrolls as:
//!
//!   1. `pb = P b`        (permute the right-hand side by rows)
//!   2. `L y = pb`        (sparse forward substitution)
//!   3. `U z = y`         (sparse back substitution, in column order)
//!   4. `x = Q^{-1} z`    (undo the AMD column permutation)
//!
//! All operations are performed using the underlying CSC L and U — there
//! is no dense expansion.

use crate::dense_vec::DenseVec;
use crate::lu::LuFactors;
use crate::sparse_lu;
use pisim_core::SimError;

/// Solve `A x = b` given LU factors from `lu_factorize`.
pub fn lu_solve(factors: &LuFactors, b: &DenseVec) -> Result<DenseVec, SimError> {
    let n = factors.n;
    assert_eq!(b.len(), n, "lu_solve: dimension mismatch");

    // Step 1: forward solve  L y = b   (the row permutation is folded into
    // the forward solve itself).
    let mut y = vec![0.0f64; n];
    sparse_lu::forward_solve_inplace(&factors.inner, b.as_slice(), &mut y);

    // Step 2: back solve  U z = y    (z is in the AMD-permuted column space).
    let mut z = vec![0.0f64; n];
    sparse_lu::back_solve_inplace(&factors.inner, &y, &mut z)?;

    // Step 3: undo the AMD column permutation.  factors.inner.col_perm maps
    // ORIGINAL column index -> permuted column index, so the solution in
    // the original numbering is x[orig] = z[col_perm.forward()[orig]].
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
    use crate::csc::CscMatrix;
    use crate::lu::lu_factorize;
    use crate::triplet::TripletMatrix;

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
}
