//! Sparse left-looking Gilbert-Peierls LU factorisation with partial
//! pivoting.
//!
//! References:
//!   Gilbert & Peierls, "Sparse partial pivoting in time proportional to
//!   arithmetic operations" (1988).
//!   Davis, "Direct Methods for Sparse Linear Systems" (2006), chapter 6.
//!
//! Algorithm overview (factorising column k of A):
//!   1. Symbolic step — compute the nonzero pattern of L(:,k) and U(:,k):
//!        x = solve L(0:k-1, 0:k-1) * y = A(:,k) symbolically by performing
//!        a depth-first search over the directed graph induced by L^T,
//!        starting from the row indices of A(:,k).  The DFS yields a
//!        topological ordering of the touched rows, which is exactly the
//!        order in which the numeric step must update them.
//!   2. Scatter A(:,k) into a dense work vector `x`.
//!   3. Numeric step — for each row j in topological order (j < k):
//!        x[i] -= L(i,j) * x[j]   for i in pattern below j
//!   4. Partial pivoting — find row p in {k..n} with the largest |x[i]|.
//!      Swap rows k and p in L's row-permutation tracking.
//!   5. Pivot value goes into U(k,k); the column entries above k go into
//!      U(:,k); the entries below k, divided by the pivot, go into L(:,k).
//!   6. Clear only the touched entries of `x` (not the whole vector).
//!
//! The work vector `x` and the marking arrays are reused across columns,
//! giving O(flops + nnz(L) + nnz(U)) per factorisation.

use crate::csc::CscMatrix;
use crate::permutation::Permutation;
use bigospice_core::SimError;

/// Sparse LU factors stored as two CSC matrices plus a row permutation.
///
/// `PA = LU` where:
///   - `P` is the row permutation produced by partial pivoting
///   - `L` is unit lower triangular (diagonal stored explicitly as 1.0)
///   - `U` is upper triangular (diagonal stored explicitly)
///
/// Both L and U use the same sorted-by-row CSC layout as
/// [`crate::csc::CscMatrix`], but are kept private here to avoid coupling.
#[derive(Debug, Clone)]
pub(crate) struct SparseLuFactors {
    pub n: usize,

    // L factor in CSC. Column j of L spans `l_col_ptr[j]..l_col_ptr[j+1]`.
    // Within each column, row indices are stored in numeric (DFS-topological)
    // order — NOT sorted, but that is fine for triangular solves because we
    // walk the column once.  The diagonal 1.0 is the FIRST entry of every
    // column (row index = j).
    pub l_col_ptr: Vec<usize>,
    pub l_row_idx: Vec<u32>,
    pub l_values: Vec<f64>,

    // U factor in CSC.  The diagonal is the LAST entry of each column
    // (row index = j).
    pub u_col_ptr: Vec<usize>,
    pub u_row_idx: Vec<u32>,
    pub u_values: Vec<f64>,

    /// Row permutation: `row_perm.forward()[orig_row] = new_row`.
    pub row_perm: Permutation,

    /// Optional column permutation (fill-reducing).  When non-identity, the
    /// caller must apply it before solving.
    pub col_perm: Permutation,
}

impl SparseLuFactors {
    /// Look up L[i, j] (slow O(col-length) — only used by legacy callers).
    pub fn l_get(&self, i: usize, j: usize) -> f64 {
        let start = self.l_col_ptr[j];
        let end = self.l_col_ptr[j + 1];
        for k in start..end {
            if self.l_row_idx[k] as usize == i {
                return self.l_values[k];
            }
        }
        0.0
    }

    /// Look up U[i, j] (slow — legacy only).
    pub fn u_get(&self, i: usize, j: usize) -> f64 {
        let start = self.u_col_ptr[j];
        let end = self.u_col_ptr[j + 1];
        for k in start..end {
            if self.u_row_idx[k] as usize == i {
                return self.u_values[k];
            }
        }
        0.0
    }
}

// ---------------------------------------------------------------------------
// Symbolic + numeric factorisation
// ---------------------------------------------------------------------------

/// Workspace reused across columns to avoid heap traffic on the hot path.
struct LuWorkspace {
    /// Dense scatter vector for the active column (length n), indexed by
    /// ORIGINAL row indices.
    x: Vec<f64>,
    /// Marker array for the DFS reach computation, indexed by PERMUTED
    /// row indices (i.e. pivot order 0..k).  `dfs_marker[k] == column_id`
    /// means permuted row k has been visited for this column.
    dfs_marker: Vec<u32>,
    /// Marker array tracking which ORIGINAL rows are already in
    /// `unpivoted_touched` for this column, to avoid duplicates.
    touch_marker: Vec<u32>,
    /// DFS stack for the reach computation (permuted-row indices).
    stack: Vec<u32>,
    /// Topologically ordered list of touched permuted rows for the
    /// current column.
    pattern: Vec<u32>,
    /// Iterator state for iterative DFS — current position within each
    /// column being traversed.  Indexed by permuted row.
    dfs_progress: Vec<u32>,
}

impl LuWorkspace {
    fn new(n: usize) -> Self {
        Self {
            x: vec![0.0; n],
            dfs_marker: vec![u32::MAX; n],
            touch_marker: vec![u32::MAX; n],
            stack: Vec::with_capacity(n),
            pattern: Vec::with_capacity(n),
            dfs_progress: vec![0; n],
        }
    }
}

/// Apply a column permutation to A: returns A * P_col, i.e. column j of the
/// output is column `col_perm.inverse()[j]` of A.  When `col_perm` is the
/// identity this just clones A.
fn permute_columns(a: &CscMatrix, col_perm: &Permutation) -> CscMatrix {
    let n = a.ncols();
    debug_assert_eq!(n, a.nrows());
    if col_perm.forward().iter().enumerate().all(|(i, &p)| i == p) {
        return a.clone();
    }
    // The new column j is the OLD column inv[j] in the original numbering,
    // i.e. col_perm sends original index i -> new index perm[i].
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

/// Build the sparse LU factorisation of `a_in`.
///
/// `col_perm` is an optional column permutation supplied by the symbolic
/// analysis (e.g. AMD).  Pass an identity permutation if none is desired.
pub(crate) fn factor(
    a_in: &CscMatrix,
    col_perm: &Permutation,
) -> Result<SparseLuFactors, SimError> {
    let n = a_in.nrows();
    assert_eq!(n, a_in.ncols(), "sparse LU requires a square matrix");

    // Apply column permutation up-front so the rest of the routine works
    // on the permuted matrix.
    let a = permute_columns(a_in, col_perm);

    let mut l_col_ptr = Vec::with_capacity(n + 1);
    let mut l_row_idx: Vec<u32> = Vec::new();
    let mut l_values: Vec<f64> = Vec::new();
    let mut u_col_ptr = Vec::with_capacity(n + 1);
    let mut u_row_idx: Vec<u32> = Vec::new();
    let mut u_values: Vec<f64> = Vec::new();
    l_col_ptr.push(0usize);
    u_col_ptr.push(0usize);

    // Pivot tracking: pinv[orig_row] = permuted_row, or u32::MAX if not yet
    // chosen as a pivot.  This is the standard Gilbert-Peierls trick: it
    // lets `reach` operate in permuted coordinates without ever building
    // the full row permutation.
    let mut pinv: Vec<u32> = vec![u32::MAX; n];
    // Inverse of pinv: which original row became permuted row k (length n,
    // filled column-by-column).
    let mut piv_orig: Vec<u32> = Vec::with_capacity(n);

    let mut ws = LuWorkspace::new(n);

    for k in 0..n {
        // ----- Symbolic step: compute reach of A(:, k) on L's graph -----
        // We need the permuted-row indices of nonzeros of A(:, k); for rows
        // that have not yet been pivoted, treat them as "permuted row =
        // self" temporarily by giving them the row id `n + orig_row`.
        // But the standard Gilbert-Peierls formulation actually only does
        // DFS on rows that ARE already pivoted.  Unpivoted rows contribute
        // a leaf in the pattern but are not entry points to descend into.
        //
        // Concretely: for each nonzero row i of A(:,k):
        //   - if pinv[i] != MAX, descend into L(:, pinv[i]).
        //   - if pinv[i] == MAX, mark i as a touched (unpivoted) row.

        let column_id = (k as u32).wrapping_add(1); // never zero
        ws.pattern.clear();

        // Pre-mark unpivoted touched rows so the scatter step knows which
        // dense entries to clear at the end.  We use a separate marker
        // namespace by storing them in a side list.
        // Strategy: do DFS over already-pivoted rows; record unpivoted
        // touched rows separately and append them at the end.
        let mut unpivoted_touched: Vec<u32> = Vec::new();

        // Manually run the DFS so we can branch on pivoted vs. unpivoted.
        for (orig_row, _v) in a.column(k) {
            let pi = pinv[orig_row];
            if pi == u32::MAX {
                // Not yet pivoted — leaf.  Use the original-row marker.
                if ws.touch_marker[orig_row] != column_id {
                    ws.touch_marker[orig_row] = column_id;
                    unpivoted_touched.push(orig_row as u32);
                }
                continue;
            }
            let start_node = pi;
            if ws.dfs_marker[start_node as usize] == column_id {
                continue;
            }
            // Iterative DFS over L's column graph in permuted coordinates.
            ws.stack.clear();
            ws.stack.push(start_node);
            ws.dfs_marker[start_node as usize] = column_id;
            // Skip the diagonal entry (which is the first entry of each
            // L column).
            let s_us = start_node as usize;
            let col_start = l_col_ptr[s_us];
            ws.dfs_progress[s_us] = (col_start + 1) as u32; // skip diagonal

            while let Some(&top) = ws.stack.last() {
                let top_us = top as usize;
                let col_end = l_col_ptr[top_us + 1] as u32;
                let mut p = ws.dfs_progress[top_us];
                let mut descended = false;
                while p < col_end {
                    // L stores row indices in the ORIGINAL numbering of A.
                    // For DFS we need to translate them via pinv.
                    let orig_child = l_row_idx[p as usize] as usize;
                    p += 1;
                    let child_pi = pinv[orig_child];
                    if child_pi == u32::MAX {
                        // Leaf — unpivoted row, mark in the touch marker.
                        if ws.touch_marker[orig_child] != column_id {
                            ws.touch_marker[orig_child] = column_id;
                            unpivoted_touched.push(orig_child as u32);
                        }
                        continue;
                    }
                    let child = child_pi;
                    if ws.dfs_marker[child as usize] != column_id {
                        ws.dfs_marker[child as usize] = column_id;
                        ws.dfs_progress[top_us] = p;
                        // Skip diagonal of the child column.
                        let cs = l_col_ptr[child as usize];
                        ws.dfs_progress[child as usize] = (cs + 1) as u32;
                        ws.stack.push(child);
                        descended = true;
                        break;
                    }
                }
                if !descended {
                    ws.dfs_progress[top_us] = p;
                    ws.pattern.push(top);
                    ws.stack.pop();
                }
            }
        }

        // ws.pattern currently holds permuted-row indices in REVERSE
        // topological order.  Reverse it so the numeric step processes
        // ancestors first.
        ws.pattern.reverse();

        // ----- Numeric scatter: x = A(:, k) -----
        // Note: x is indexed by ORIGINAL row indices.  We will reconcile
        // with permuted indices via pinv as we process.
        for (orig_row, v) in a.column(k) {
            ws.x[orig_row] = v;
        }

        // ----- Numeric solve: x = L \ x for the upper part -----
        // Process pivoted rows in topological order.  Each entry
        // permuted_row p corresponds to original row piv_orig[p].
        // L(:, p) holds the multipliers; we do x -= L(:, p) * x[piv_orig[p]].
        for &pr in ws.pattern.iter() {
            let pr_us = pr as usize;
            let orig_pivot_row = piv_orig[pr_us] as usize;
            let xj = ws.x[orig_pivot_row];
            if xj == 0.0 {
                continue;
            }
            // Walk L(:, pr).  Skip the diagonal (first entry == orig_pivot_row).
            let cs = l_col_ptr[pr_us];
            let ce = l_col_ptr[pr_us + 1];
            // Diagonal is at offset cs.
            for off in (cs + 1)..ce {
                let orig_row = l_row_idx[off] as usize;
                ws.x[orig_row] -= l_values[off] * xj;
            }
        }

        // ----- Partial pivoting: pick the largest |x[i]| among unpivoted i -----
        // Candidates are the rows in `unpivoted_touched`.
        let mut best_row: i64 = -1;
        let mut best_val = 0.0f64;
        for &orig in unpivoted_touched.iter() {
            let v = ws.x[orig as usize].abs();
            if v > best_val {
                best_val = v;
                best_row = orig as i64;
            }
        }
        // Also consider rows in the U-pattern that may have been touched
        // (this handles the case where A(:,k) has values on rows that are
        // already pivoted — those rows form U entries, not pivot candidates).

        if best_row < 0 || best_val < 1e-30 {
            return Err(SimError::SingularMatrix { row: k });
        }
        let pivot_orig = best_row as usize;
        let pivot_val = ws.x[pivot_orig];

        // Assign the pivot: original row `pivot_orig` becomes permuted row k.
        pinv[pivot_orig] = k as u32;
        piv_orig.push(pivot_orig as u32);

        // ----- Emit U(:, k) -----
        // U(:, k) contains entries for permuted rows < k (i.e. already pivoted)
        // PLUS the pivot itself on the diagonal.  We walk the topological
        // pattern (which contains permuted indices < k by construction).
        for &pr in ws.pattern.iter() {
            let pr_us = pr as usize;
            let orig_row = piv_orig[pr_us] as usize;
            let v = ws.x[orig_row];
            if v != 0.0 {
                u_row_idx.push(pr as u32);
                u_values.push(v);
            }
            ws.x[orig_row] = 0.0;
        }
        // Diagonal (last entry of U column).
        u_row_idx.push(k as u32);
        u_values.push(pivot_val);
        u_col_ptr.push(u_row_idx.len());

        // ----- Emit L(:, k) -----
        // L(:, k) gets a unit diagonal first (row index k in permuted
        // numbering, but stored as ORIGINAL row pivot_orig so the numeric
        // scatter logic in subsequent columns works directly with original
        // row indices).
        l_row_idx.push(pivot_orig as u32);
        l_values.push(1.0);
        ws.x[pivot_orig] = 0.0;
        // Then the remaining unpivoted touched rows (these become future
        // pivot candidates), divided by the pivot.
        for &orig in unpivoted_touched.iter() {
            let orig_us = orig as usize;
            if orig_us == pivot_orig {
                continue;
            }
            let v = ws.x[orig_us];
            ws.x[orig_us] = 0.0;
            if v != 0.0 {
                l_row_idx.push(orig);
                l_values.push(v / pivot_val);
            }
        }
        l_col_ptr.push(l_row_idx.len());
    }

    // Build the row permutation from piv_orig.
    // piv_orig[k] = original row that became permuted row k.
    // Permutation::from_vec wants `perm[i]` = position element i maps to.
    // We have inv[k] = piv_orig[k]; so perm = inverse(piv_orig).
    let inv: Vec<usize> = piv_orig.iter().map(|&x| x as usize).collect();
    let mut perm = vec![0usize; n];
    for (k, &orig) in inv.iter().enumerate() {
        perm[orig] = k;
    }
    let row_perm = Permutation::from_vec(perm);

    Ok(SparseLuFactors {
        n,
        l_col_ptr,
        l_row_idx,
        l_values,
        u_col_ptr,
        u_row_idx,
        u_values,
        row_perm,
        col_perm: col_perm.clone(),
    })
}

// ---------------------------------------------------------------------------
// Sparse triangular solves
// ---------------------------------------------------------------------------

/// Forward substitution: solve L * y = b where L is unit lower triangular
/// stored in CSC, with the diagonal as the FIRST entry of each column and
/// row indices in the ORIGINAL (pre-permutation) numbering.
///
/// Operates in-place on `x` (which on entry is `b` in original numbering,
/// and on exit is `y` in permuted numbering).
///
/// We process columns in pivot order: for column k (i.e. the k-th pivot),
/// `y[k] = x[orig_pivot_row]`, then propagate by subtracting the column.
pub(crate) fn forward_solve_inplace(
    factors: &SparseLuFactors,
    rhs: &[f64],
    out: &mut [f64],
) {
    let n = factors.n;
    debug_assert_eq!(rhs.len(), n);
    debug_assert_eq!(out.len(), n);

    // Scatter rhs into a working buffer indexed by ORIGINAL rows.
    // We can reuse `out` for this if we permute carefully.
    // For simplicity: copy rhs into a temp buffer addressed by original row
    // indices, then process columns 0..n.
    // The temp buffer is `out` itself: load rhs into out[orig_row].
    out.copy_from_slice(rhs);

    // forward()[orig] = permuted index k.
    // inverse()[k]   = orig row that became pivot k.
    let inv = factors.row_perm.inverse();

    // y[k] (in permuted numbering) is what we want; we'll store it back
    // into out[k] AFTER all original-row work is done.  To avoid two
    // buffers, we proceed column-by-column and overwrite as we go,
    // remembering that out[ orig ] holds the live value.
    //
    // After column k is processed, the orig pivot row's slot in out can
    // be reused to hold y[k] in permuted numbering — but downstream
    // columns reference original-row entries, so we keep two passes:
    //   pass 1: compute y[k] in a temp Vec.
    //   pass 2: write into out.

    // Use a small auxiliary buffer.  This is the only allocation in the
    // hot path; for n in the thousands it is negligible relative to LU
    // work, and avoids tricky aliasing.
    let mut y = vec![0.0f64; n];

    for k in 0..n {
        let orig = inv[k];
        let yk = out[orig];
        y[k] = yk;
        if yk == 0.0 {
            continue;
        }
        let cs = factors.l_col_ptr[k];
        let ce = factors.l_col_ptr[k + 1];
        // Skip diagonal at offset cs (value = 1.0).
        for off in (cs + 1)..ce {
            let r = factors.l_row_idx[off] as usize;
            out[r] -= factors.l_values[off] * yk;
        }
    }

    out.copy_from_slice(&y);
}

/// Back substitution: solve U * x = y where U is upper triangular stored in
/// CSC with the diagonal as the LAST entry of each column.  Both vectors
/// are indexed in the permuted (pivot) ordering.
pub(crate) fn back_solve_inplace(
    factors: &SparseLuFactors,
    y: &[f64],
    out: &mut [f64],
) -> Result<(), SimError> {
    let n = factors.n;
    debug_assert_eq!(y.len(), n);
    debug_assert_eq!(out.len(), n);
    out.copy_from_slice(y);

    for k in (0..n).rev() {
        let cs = factors.u_col_ptr[k];
        let ce = factors.u_col_ptr[k + 1];
        // Diagonal is the last entry.
        let diag_off = ce - 1;
        debug_assert_eq!(factors.u_row_idx[diag_off] as usize, k);
        let diag = factors.u_values[diag_off];
        if diag.abs() < 1e-30 {
            return Err(SimError::SingularMatrix { row: k });
        }
        let xk = out[k] / diag;
        out[k] = xk;
        if xk == 0.0 {
            continue;
        }
        for off in cs..diag_off {
            let r = factors.u_row_idx[off] as usize;
            out[r] -= factors.u_values[off] * xk;
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dense_vec::DenseVec;
    use crate::triplet::TripletMatrix;

    fn solve(a: &CscMatrix, b: &[f64]) -> Vec<f64> {
        let id = Permutation::identity(a.ncols());
        let factors = factor(a, &id).unwrap();
        let mut y = vec![0.0; b.len()];
        forward_solve_inplace(&factors, b, &mut y);
        let mut x_perm = vec![0.0; b.len()];
        back_solve_inplace(&factors, &y, &mut x_perm).unwrap();
        // x_perm is in permuted-column order; with identity col_perm it
        // equals the original ordering.
        x_perm
    }

    #[test]
    fn identity_matrix_5x5() {
        let id = CscMatrix::identity(5);
        let b = [1.0, 2.0, 3.0, 4.0, 5.0];
        let x = solve(&id, &b);
        for i in 0..5 {
            assert!((x[i] - b[i]).abs() < 1e-14);
        }
    }

    #[test]
    fn diagonal_matrix() {
        let mut t = TripletMatrix::new(4, 4);
        t.add(0, 0, 2.0);
        t.add(1, 1, 3.0);
        t.add(2, 2, 4.0);
        t.add(3, 3, 5.0);
        let a = t.to_csc();
        let b = [2.0, 6.0, 12.0, 20.0];
        let x = solve(&a, &b);
        let expected = [1.0, 2.0, 3.0, 4.0];
        for i in 0..4 {
            assert!((x[i] - expected[i]).abs() < 1e-12, "x[{i}]={}", x[i]);
        }
    }

    #[test]
    fn small_dense_3x3() {
        // [2  1  0]
        // [1  3  1]
        // [0  1  4]
        let mut t = TripletMatrix::new(3, 3);
        t.add(0, 0, 2.0);
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        t.add(1, 1, 3.0);
        t.add(1, 2, 1.0);
        t.add(2, 1, 1.0);
        t.add(2, 2, 4.0);
        let a = t.to_csc();
        let x_true = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let b = a.mul_vec(&x_true);
        let x = solve(&a, b.as_slice());
        for i in 0..3 {
            assert!((x[i] - x_true[i]).abs() < 1e-12, "x[{i}]={} expected {}", x[i], x_true[i]);
        }
    }

    #[test]
    fn circuit_like_5x5_with_pivoting() {
        // A nodal-like matrix with off-diagonal fill and a near-zero
        // diagonal that forces pivoting.
        // [ 0   2   0   1   0]
        // [ 1   0   3   0   0]
        // [ 0   1   0   2   1]
        // [ 2   0   1   4   0]
        // [ 0   0   1   0   3]
        let mut t = TripletMatrix::new(5, 5);
        t.add(0, 1, 2.0);
        t.add(0, 3, 1.0);
        t.add(1, 0, 1.0);
        t.add(1, 2, 3.0);
        t.add(2, 1, 1.0);
        t.add(2, 3, 2.0);
        t.add(2, 4, 1.0);
        t.add(3, 0, 2.0);
        t.add(3, 2, 1.0);
        t.add(3, 3, 4.0);
        t.add(4, 2, 1.0);
        t.add(4, 4, 3.0);
        let a = t.to_csc();
        let x_true = DenseVec::from_slice(&[1.0, -2.0, 3.0, -4.0, 5.0]);
        let b = a.mul_vec(&x_true);
        let x = solve(&a, b.as_slice());
        for i in 0..5 {
            assert!(
                (x[i] - x_true[i]).abs() < 1e-10,
                "x[{i}]={} expected {}",
                x[i],
                x_true[i]
            );
        }
    }

    #[test]
    fn singular_returns_error() {
        // Row/col 1 entirely zero.
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 1.0);
        t.add(0, 1, 1.0);
        let a = t.to_csc();
        let id = Permutation::identity(2);
        assert!(factor(&a, &id).is_err());
    }
}
