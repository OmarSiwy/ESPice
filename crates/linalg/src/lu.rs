//! Public LU factorisation API.
//!
//! Internally this is now a real **sparse left-looking Gilbert-Peierls LU
//! with partial pivoting** plus a BTF pre-ordering and AMD column ordering —
//! see [`crate::sparse_lu`], [`crate::amd`], and [`crate::btf`].
//!
//! The solve pipeline is:
//!   `P_btf_row * A * P_btf_col^{-1} = A'`  (BTF permutation)
//!   `P_lu_row * A' * Q_amd^{-1} = L * U`   (AMD + Gilbert-Peierls LU)
//!
//! `lu_solve` undoes both permutations automatically.

use crate::amd;
use crate::btf::btf_decompose;
use crate::csc::CscMatrix;
use crate::permutation::Permutation;
use crate::sparse_lu::{self, SparseLuFactors};
use bigospice_core::SimError;

/// Symbolic analysis result for LU factorisation.
///
/// Holds the BTF row permutation and the combined BTF+AMD column ordering.
/// Numerical refactorisation reuses this so the (relatively expensive)
/// ordering steps are paid only once per Newton sweep.
#[derive(Debug, Clone)]
pub struct LuSymbolic {
    pub n: usize,
    /// Row permutation placeholder — populated by the numeric step.
    pub row_perm: Permutation,
    /// Combined column permutation: BTF col perm composed with AMD.
    /// `col_perm.forward()[orig_col]` = permuted col index used by LU.
    pub col_perm: Permutation,
    /// BTF row permutation: `btf_row_perm.forward()[orig_row]` = permuted row.
    /// Applied to the RHS before the forward solve.
    pub btf_row_perm: Permutation,
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
    /// BTF row permutation applied to the RHS before solving.
    pub(crate) btf_row_perm: Permutation,
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

/// Permute rows of a CSC matrix: returns `row_perm * A`.
///
/// `row_perm.forward()[orig_row] = new_row` — each row index in the
/// output is `row_perm[orig_row]`.  Column structure is unchanged; row
/// indices within each column are re-mapped and then re-sorted.
fn permute_rows(a: &CscMatrix, row_perm: &Permutation) -> CscMatrix {
    let n = a.nrows();
    debug_assert_eq!(n, a.ncols());
    if row_perm.forward().iter().enumerate().all(|(i, &p)| i == p) {
        return a.clone();
    }
    let fwd = row_perm.forward();
    let mut col_ptr = Vec::with_capacity(n + 1);
    let mut row_idx = Vec::with_capacity(a.nnz());
    let mut values = Vec::with_capacity(a.nnz());
    col_ptr.push(0usize);
    for j in 0..n {
        // Collect (new_row, value) pairs for this column.
        let mut pairs: Vec<(usize, f64)> = a
            .column(j)
            .map(|(orig_r, v)| (fwd[orig_r], v))
            .collect();
        // Re-sort by new row index so the CSC invariant holds.
        pairs.sort_unstable_by_key(|&(r, _)| r);
        for (r, v) in pairs {
            row_idx.push(r);
            values.push(v);
        }
        col_ptr.push(row_idx.len());
    }
    CscMatrix::new(n, n, col_ptr, row_idx, values)
}

/// Symbolic analysis: run BTF pre-ordering then AMD fill-reducing ordering.
///
/// The combined column permutation `col_perm` is `Q_amd ∘ P_btf_col`:
/// `col_perm.forward()[orig_col]` is the column index seen by the numeric LU.
/// The BTF row permutation `btf_row_perm` is applied to the RHS in `lu_solve`.
pub fn lu_symbolic(a: &CscMatrix) -> LuSymbolic {
    assert_eq!(a.nrows(), a.ncols(), "LU requires a square matrix");
    let n = a.nrows();

    // Step 1: BTF decomposition — find P_btf_row, P_btf_col.
    let btf = btf_decompose(a);
    let btf_row_perm = btf.p_row.clone();
    let btf_col_perm = btf.p_col.clone();

    // Step 2: Apply BTF permutation to get A' = P_btf_row * A * P_btf_col^{-1}.
    // First permute rows, then permute columns.
    let a_row_permuted = permute_rows(a, &btf_row_perm);
    // `permute_columns` is in sparse_lu; replicate the col permutation here
    // using btf_col_perm.  Column j of A' = column inv[j] of a_row_permuted.
    let btf_col_inv = btf_col_perm.inverse();
    let mut col_ptr_p = Vec::with_capacity(n + 1);
    let mut row_idx_p: Vec<usize> = Vec::with_capacity(a.nnz());
    let mut values_p: Vec<f64> = Vec::with_capacity(a.nnz());
    col_ptr_p.push(0usize);
    for j in 0..n {
        let orig_col = btf_col_inv[j];
        for (r, v) in a_row_permuted.column(orig_col) {
            row_idx_p.push(r);
            values_p.push(v);
        }
        col_ptr_p.push(row_idx_p.len());
    }
    let a_btf = CscMatrix::new(n, n, col_ptr_p, row_idx_p, values_p);

    // Step 3: AMD on the BTF-permuted matrix.
    let amd_perm = amd::amd_order(&a_btf);

    // Step 4: Compose col_perm = Q_amd ∘ P_btf_col.
    // We want col_perm.forward()[orig_col] = amd_perm.forward()[btf_col_perm.forward()[orig_col]].
    let amd_fwd = amd_perm.forward();
    let btf_col_fwd = btf_col_perm.forward();
    let composed: Vec<usize> = (0..n)
        .map(|orig| amd_fwd[btf_col_fwd[orig]])
        .collect();
    let col_perm = Permutation::from_vec(composed);

    LuSymbolic {
        n,
        row_perm: Permutation::identity(n),
        col_perm,
        btf_row_perm,
    }
}

/// Full sparse LU factorisation with partial pivoting (BTF + AMD + G-P LU).
pub fn lu_factorize(a: &CscMatrix) -> Result<LuFactors, SimError> {
    let symbolic = lu_symbolic(a);
    lu_refactorize(a, &symbolic)
}

/// Numerical refactorisation reusing an existing symbolic pattern.
///
/// Applies the BTF row permutation to `a` before invoking Gilbert-Peierls LU
/// with the combined BTF+AMD column permutation.  This is the fast path for
/// Newton iterations where the sparsity pattern is stable but values change.
pub fn lu_refactorize(
    a: &CscMatrix,
    symbolic: &LuSymbolic,
) -> Result<LuFactors, SimError> {
    // Apply the BTF row permutation: A_p = P_btf_row * A.
    let a_row_permuted = permute_rows(a, &symbolic.btf_row_perm);
    // factor() applies the column permutation internally.
    let inner = sparse_lu::factor(&a_row_permuted, &symbolic.col_perm)?;
    Ok(LuFactors {
        n: inner.n,
        row_perm: inner.row_perm.clone(),
        inner,
        btf_row_perm: symbolic.btf_row_perm.clone(),
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
