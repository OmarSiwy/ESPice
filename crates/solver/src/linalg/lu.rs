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

use super::amd;
use super::btf::btf_decompose;
use super::csc::CscMatrix;
use super::permutation::Permutation;
use super::sparse_lu::{self, SparseLuFactors};
use incspice_core::SimError;

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
        let mut pairs: Vec<(usize, f64)> =
            a.column(j).map(|(orig_r, v)| (fwd[orig_r], v)).collect();
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

/// Permute columns of a CSC matrix: returns `A * col_perm^{-1}`.
///
/// `col_perm.forward()[orig_col] = new_col`, so output column `new_col`
/// receives original column `orig_col`.
fn permute_columns(a: &CscMatrix, col_perm: &Permutation) -> CscMatrix {
    let n = a.ncols();
    debug_assert_eq!(n, a.nrows());
    if col_perm.forward().iter().enumerate().all(|(i, &p)| i == p) {
        return a.clone();
    }

    let inv = col_perm.inverse();
    let mut col_ptr = Vec::with_capacity(n + 1);
    let mut row_idx = Vec::with_capacity(a.nnz());
    let mut values = Vec::with_capacity(a.nnz());
    col_ptr.push(0usize);
    for j in 0..n {
        let orig_col = inv[j];
        for (r, v) in a.column(orig_col) {
            row_idx.push(r);
            values.push(v);
        }
        col_ptr.push(row_idx.len());
    }
    CscMatrix::new(n, n, col_ptr, row_idx, values)
}

/// Extract the diagonal submatrix `a[range, range]`, re-indexed to `0..m`.
fn extract_diagonal_block(a: &CscMatrix, range: std::ops::Range<usize>) -> CscMatrix {
    let m = range.end - range.start;
    if m == 0 {
        return CscMatrix::zeros(0, 0);
    }

    let mut col_ptr = Vec::with_capacity(m + 1);
    let mut row_idx = Vec::new();
    let mut values = Vec::new();
    col_ptr.push(0usize);

    for col in range.clone() {
        for (row, value) in a.column(col) {
            if range.contains(&row) {
                row_idx.push(row - range.start);
                values.push(value);
            }
        }
        col_ptr.push(row_idx.len());
    }

    CscMatrix::new(m, m, col_ptr, row_idx, values)
}

/// Run AMD independently inside each BTF diagonal block.
///
/// This preserves the block-triangular structure found by BTF while still
/// reducing fill inside each strongly connected component.
fn block_amd_order(a_btf: &CscMatrix, block_starts: &[usize]) -> Permutation {
    let n = a_btf.ncols();
    if n <= 1 {
        return Permutation::identity(n);
    }

    let mut perm = vec![0usize; n];
    for block in block_starts.windows(2) {
        let start = block[0];
        let end = block[1];
        let size = end - start;

        if size <= 1 {
            if size == 1 {
                perm[start] = start;
            }
            continue;
        }

        let block_matrix = extract_diagonal_block(a_btf, start..end);
        let block_perm = amd::amd_order(&block_matrix);
        for local_col in 0..size {
            perm[start + local_col] = start + block_perm.forward()[local_col];
        }
    }

    Permutation::from_vec(perm)
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
    let a_row_permuted = permute_rows(a, &btf_row_perm);
    let a_btf = permute_columns(&a_row_permuted, &btf_col_perm);

    // Step 3: AMD independently inside each BTF diagonal block.
    let amd_perm = block_amd_order(&a_btf, &btf.block_starts);

    // Step 4: Compose col_perm = Q_amd ∘ P_btf_col.
    // We want col_perm.forward()[orig_col] = amd_perm.forward()[btf_col_perm.forward()[orig_col]].
    let amd_fwd = amd_perm.forward();
    let btf_col_fwd = btf_col_perm.forward();
    let composed: Vec<usize> = (0..n).map(|orig| amd_fwd[btf_col_fwd[orig]]).collect();
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
pub fn lu_refactorize(a: &CscMatrix, symbolic: &LuSymbolic) -> Result<LuFactors, SimError> {
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
    use crate::linalg::btf::btf_decompose;
    use crate::linalg::dense_vec::DenseVec;
    use crate::linalg::solve::lu_solve;
    use crate::linalg::triplet::TripletMatrix;

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

    fn build_two_block_upper_triangular() -> CscMatrix {
        let mut t = TripletMatrix::new(5, 5);

        // 3x3 irreducible block.
        t.add(0, 0, 4.0);
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        t.add(1, 1, 3.0);
        t.add(1, 2, 1.0);
        t.add(2, 1, 1.0);
        t.add(2, 2, 2.0);

        // Upper off-diagonal coupling into the second block.
        t.add(0, 3, 0.5);
        t.add(1, 4, 0.25);

        // 2x2 irreducible block.
        t.add(3, 3, 5.0);
        t.add(3, 4, 1.0);
        t.add(4, 3, 1.0);
        t.add(4, 4, 4.0);

        t.to_csc()
    }

    fn block_of(index: usize, block_starts: &[usize]) -> usize {
        block_starts
            .windows(2)
            .position(|block| index >= block[0] && index < block[1])
            .unwrap()
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

    #[test]
    fn symbolic_keeps_columns_inside_btf_blocks() {
        let a = build_two_block_upper_triangular();
        let btf = btf_decompose(&a);
        assert_eq!(btf.block_count, 2, "expected two BTF blocks");

        let symbolic = lu_symbolic(&a);
        for orig_col in 0..a.ncols() {
            let btf_pos = btf.p_col.forward()[orig_col];
            let block = block_of(btf_pos, &btf.block_starts);
            let start = btf.block_starts[block];
            let end = btf.block_starts[block + 1];
            let final_pos = symbolic.col_perm.forward()[orig_col];

            assert!(
                (start..end).contains(&final_pos),
                "column {orig_col} moved from BTF block {block} range {start}..{end} to {final_pos}"
            );
        }
    }

    #[test]
    fn solve_reducible_block_triangular_system() {
        let a = build_two_block_upper_triangular();
        let factors = lu_factorize(&a).unwrap();
        let x_true = DenseVec::from_slice(&vec![1.0, -2.0, 0.5, 3.0, -1.0]);
        let b = a.mul_vec(&x_true);
        let x = lu_solve(&factors, &b).unwrap();

        for i in 0..a.ncols() {
            assert!(
                (x[i] - x_true[i]).abs() < 1e-11,
                "x[{i}] = {} expected {}",
                x[i],
                x_true[i]
            );
        }
    }

    #[test]
    fn lu_solve_2x2_system() {
        // [2 1; 1 3] * [x1; x2] = [5; 10]  => x1=1, x2=3
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 2.0);
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        t.add(1, 1, 3.0);
        let csc = t.to_csc();
        let factors = lu_factorize(&csc).unwrap();
        let mut rhs = DenseVec::zeros(2);
        rhs[0] = 5.0;
        rhs[1] = 10.0;
        let x = lu_solve(&factors, &rhs).unwrap();
        assert!((x[0] - 1.0).abs() < 1e-10, "x[0]={}", x[0]);
        assert!((x[1] - 3.0).abs() < 1e-10, "x[1]={}", x[1]);
    }

    #[test]
    fn lu_solve_diagonal_5x5() {
        // Diagonal matrix diag(1,2,3,4,5), rhs = [1,2,3,4,5] => x = [1,1,1,1,1]
        let mut t = TripletMatrix::new(5, 5);
        for i in 0..5 {
            t.add(i, i, (i + 1) as f64);
        }
        let csc = t.to_csc();
        let factors = lu_factorize(&csc).unwrap();
        let rhs = DenseVec::from_slice(&[1.0, 2.0, 3.0, 4.0, 5.0]);
        let x = lu_solve(&factors, &rhs).unwrap();
        for i in 0..5 {
            assert!((x[i] - 1.0).abs() < 1e-12, "x[{i}]={}", x[i]);
        }
    }

    #[test]
    fn lu_solve_negative_rhs() {
        // identity * x = [-1, -2, -3] => x = [-1, -2, -3]
        let id = CscMatrix::identity(3);
        let factors = lu_factorize(&id).unwrap();
        let b = DenseVec::from_slice(&[-1.0, -2.0, -3.0]);
        let x = lu_solve(&factors, &b).unwrap();
        for i in 0..3 {
            assert!((x[i] - b[i]).abs() < 1e-14);
        }
    }

    #[test]
    fn lu_solve_zero_rhs_gives_zero_solution() {
        let a = build_3x3();
        let factors = lu_factorize(&a).unwrap();
        let b = DenseVec::zeros(3);
        let x = lu_solve(&factors, &b).unwrap();
        for i in 0..3 {
            assert!(x[i].abs() < 1e-14, "x[{i}]={}", x[i]);
        }
    }

    #[test]
    fn lu_refactorize_matches_fresh_factorize() {
        let a = build_3x3();
        let symbolic = lu_symbolic(&a);
        let refactored = lu_refactorize(&a, &symbolic).unwrap();
        let fresh = lu_factorize(&a).unwrap();

        let x_true = DenseVec::from_slice(&[2.0, -1.0, 0.5]);
        let b = a.mul_vec(&x_true);
        let x_ref = lu_solve(&refactored, &b).unwrap();
        let x_fresh = lu_solve(&fresh, &b).unwrap();

        for i in 0..3 {
            assert!((x_ref[i] - x_fresh[i]).abs() < 1e-12, "i={i}");
        }
    }

    #[test]
    fn lu_symbolic_has_correct_n() {
        let a = build_3x3();
        let sym = lu_symbolic(&a);
        assert_eq!(sym.n, 3);
    }

    #[test]
    fn lu_symbolic_col_perm_is_valid_permutation() {
        let a = build_3x3();
        let sym = lu_symbolic(&a);
        let fwd = sym.col_perm.forward();
        let n = fwd.len();
        let mut seen = vec![false; n];
        for &p in fwd {
            assert!(p < n);
            assert!(!seen[p]);
            seen[p] = true;
        }
    }

    #[test]
    fn lu_factors_n_matches_matrix_dimension() {
        // Verify that the LuFactors n field matches the matrix dimension
        let a = build_3x3();
        let factors = lu_factorize(&a).unwrap();
        assert_eq!(factors.n, 3);
        // Verify that row_perm is a valid permutation of length n
        let fwd = factors.row_perm.forward();
        assert_eq!(fwd.len(), 3);
        let mut seen = vec![false; 3];
        for &p in fwd {
            assert!(p < 3);
            assert!(!seen[p]);
            seen[p] = true;
        }
    }
}
