//! Public LU factorisation API.
//!
//! Internally this is now a real **sparse left-looking Gilbert-Peierls LU
//! with partial pivoting** plus an AMD column ordering — see
//! [`crate::sparse_lu`] and [`crate::amd`].  The previous dense O(n^3)
//! implementation has been removed, but the public types and free
//! functions retain the same signatures so existing call-sites compile
//! unchanged.

use crate::amd;
use crate::csc::CscMatrix;
use crate::permutation::Permutation;
use crate::sparse_lu::{self, SparseLuFactors};
use pisim_core::SimError;

/// Symbolic analysis result for LU factorisation.
///
/// Holds the fill-reducing column ordering produced by AMD.  Numerical
/// refactorisation reuses this so the (relatively expensive) ordering
/// step is paid only once per Newton sweep.
#[derive(Debug, Clone)]
pub struct LuSymbolic {
    pub n: usize,
    /// Row permutation placeholder — populated by the numeric step.
    pub row_perm: Permutation,
    /// Column permutation from AMD.
    pub col_perm: Permutation,
}

/// Numeric LU factors.
///
/// The internal representation is sparse CSC for both `L` and `U`; the
/// fields are private but `n`, `row_perm`, and the legacy `l_entry` /
/// `u_entry` accessors remain available for callers that previously
/// inspected the dense layout.
#[derive(Debug, Clone)]
pub struct LuFactors {
    pub n: usize,
    pub row_perm: Permutation,
    pub(crate) inner: SparseLuFactors,
}

impl LuFactors {
    /// Look up the (i, j) entry of the L factor.  O(nnz of column j) —
    /// retained only for compatibility with the dense API; performance-
    /// sensitive code should use the sparse triangular solves directly.
    #[inline]
    pub fn l_entry(&self, i: usize, j: usize) -> f64 {
        self.inner.l_get(i, j)
    }

    /// Look up the (i, j) entry of the U factor.  O(nnz of column j).
    #[inline]
    pub fn u_entry(&self, i: usize, j: usize) -> f64 {
        self.inner.u_get(i, j)
    }
}

/// Symbolic analysis: compute a fill-reducing column ordering via AMD.
pub fn lu_symbolic(a: &CscMatrix) -> LuSymbolic {
    assert_eq!(a.nrows(), a.ncols(), "LU requires a square matrix");
    let n = a.nrows();
    let col_perm = amd::amd_order(a);
    LuSymbolic {
        n,
        row_perm: Permutation::identity(n),
        col_perm,
    }
}

/// Full sparse LU factorisation with partial pivoting.
pub fn lu_factorize(a: &CscMatrix) -> Result<LuFactors, SimError> {
    let symbolic = lu_symbolic(a);
    lu_refactorize(a, &symbolic)
}

/// Numerical refactorisation reusing an existing symbolic pattern.
///
/// In the current implementation this re-runs the full numeric phase
/// (Gilbert-Peierls), but with the AMD column ordering carried over from
/// the symbolic step.  A future version can additionally cache the L/U
/// nonzero pattern from the previous numeric solve to skip the symbolic
/// reach computation entirely.
pub fn lu_refactorize(
    a: &CscMatrix,
    symbolic: &LuSymbolic,
) -> Result<LuFactors, SimError> {
    let inner = sparse_lu::factor(a, &symbolic.col_perm)?;
    Ok(LuFactors {
        n: inner.n,
        row_perm: inner.row_perm.clone(),
        inner,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dense_vec::DenseVec;
    use crate::solve::lu_solve;
    use crate::triplet::TripletMatrix;

    fn build_3x3() -> CscMatrix {
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 2.0);
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        t.add(1, 1, 3.0);
        t.add(1, 2, 1.0);
        t.add(2, 1, 1.0);
        t.add(2, 2, 4.0);
        t.to_csc()
    }

    #[test]
    fn factorize_3x3() {
        let a = build_3x3();
        let factors = lu_factorize(&a).unwrap();
        assert_eq!(factors.n, 3);
    }

    #[test]
    fn solve_identity() {
        let id = CscMatrix::identity(3);
        let factors = lu_factorize(&id).unwrap();
        let b = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let x = lu_solve(&factors, &b).unwrap();
        for i in 0..3 {
            assert!((x[i] - b[i]).abs() < 1e-14);
        }
    }

    #[test]
    fn solve_3x3_system() {
        let a = build_3x3();
        let factors = lu_factorize(&a).unwrap();
        let x_true = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let b = a.mul_vec(&x_true);
        let x = lu_solve(&factors, &b).unwrap();
        for i in 0..3 {
            assert!(
                (x[i] - x_true[i]).abs() < 1e-12,
                "x[{i}] = {} expected {}",
                x[i],
                x_true[i]
            );
        }
    }

    #[test]
    fn singular_matrix_error() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 1.0);
        t.add(0, 1, 1.0);
        let a = t.to_csc();
        let result = lu_factorize(&a);
        assert!(result.is_err());
    }

    #[test]
    fn factorize_1x1() {
        let mut t = TripletMatrix::new(1, 1);
        t.add(0, 0, 5.0);
        let a = t.to_csc();
        let factors = lu_factorize(&a).unwrap();
        let b = DenseVec::from_slice(&[10.0]);
        let x = lu_solve(&factors, &b).unwrap();
        assert!((x[0] - 2.0).abs() < 1e-14);
    }

    #[test]
    fn needs_pivoting() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        let a = t.to_csc();
        let factors = lu_factorize(&a).unwrap();
        let b = DenseVec::from_slice(&[3.0, 7.0]);
        let x = lu_solve(&factors, &b).unwrap();
        // x = [7, 3]
        assert!((x[0] - 7.0).abs() < 1e-14);
        assert!((x[1] - 3.0).abs() < 1e-14);
    }
}
