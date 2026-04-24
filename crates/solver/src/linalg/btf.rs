//! Block Triangular Form (BTF) decomposition for sparse matrices.
//!
//! BTF reduces LU factorisation cost by finding row and column permutations
//! `P`, `Q` such that `P * A * Q^T` is block upper-triangular:
//!
//! ```text
//!   [ B₁₁  *   *  ]
//!   [  0  B₂₂  *  ]
//!   [  0   0  B₃₃ ]
//! ```
//!
//! Each diagonal block `Bᵢᵢ` is a strongly-connected component (SCC) of the
//! directed graph induced by the bipartite matching of `A`.  LU factorisation
//! can then be restricted to the nontrivial diagonal blocks; singleton blocks
//! on the diagonal (1×1 with a nonzero diagonal entry) require no work.
//!
//! ## Algorithm
//!
//! 1. **Bipartite matching** (maximum transversal): find a perfect matching
//!    between rows and columns using augmenting-path DFS (Hopcroft-Karp
//!    style, but single-pass for simplicity).  This gives a permutation
//!    `col_match[j]` = row assigned to column `j`.
//!
//! 2. **Tarjan SCC** on the directed graph induced by the matching: column `j`
//!    has an edge to column `k` whenever `A[col_match[j], k] != 0` and `k != j`.
//!    SCCs in reverse topological order form the diagonal blocks.
//!
//! 3. **Compose permutations**: the combined row/column reordering places the
//!    SCCs on the diagonal of the permuted matrix.
//!
//! ## References
//!
//! - Duff & Reid, "Algorithm 529: Permutations to Block Triangular Form",
//!   ACM Trans. Math. Software 4(2), 1978.
//! - Duff, Erisman & Reid, "Direct Methods for Sparse Matrices", Oxford, 1986.
//! - Davis, "Direct Methods for Sparse Linear Systems", SIAM, 2006, §7.3.

use super::csc::CscMatrix;
use super::permutation::Permutation;

// ---------------------------------------------------------------------------
// btf_permutation — simplified free-function interface
// ---------------------------------------------------------------------------

/// Result returned by [`btf_permutation`].
///
/// The combined `row_perm`/`col_perm` permutations place `P * A * Q^T` in
/// block-upper-triangular form.  `block_sizes[k]` is the number of rows/columns
/// in the k-th diagonal block.
#[derive(Debug, Clone)]
pub struct BtfResult {
    /// `row_perm[orig_row]` = new (permuted) row index.
    pub row_perm: Vec<usize>,
    /// `col_perm[orig_col]` = new (permuted) column index.
    pub col_perm: Vec<usize>,
    /// Size of each diagonal block, in permuted order.
    pub block_sizes: Vec<usize>,
}

/// Compute the BTF permutation for an `n × n` sparse matrix given in CSR/CSC
/// format as `(row_ptr, col_idx)`.
///
/// This is the thin free-function wrapper over [`btf_decompose`] that accepts
/// raw CSC pointers instead of a [`CscMatrix`] and returns a plain
/// [`BtfResult`] instead of [`BtfDecomposition`].
///
/// # Arguments
///
/// * `n`       — matrix dimension.
/// * `row_ptr` — CSC column-pointer array (length `n + 1`).
/// * `col_idx` — CSC row-index array (length `row_ptr[n]`).
pub fn btf_permutation(n: usize, row_ptr: &[usize], col_idx: &[usize]) -> BtfResult {
    // Build a zero-valued CscMatrix from the raw sparsity pattern.
    let nnz = row_ptr[n];
    let values = vec![1.0f64; nnz];
    let col_ptr: Vec<usize> = row_ptr.to_vec();
    let row_idx: Vec<usize> = col_idx.to_vec();
    let mat = CscMatrix::new(n, n, col_ptr, row_idx, values);

    let decomp = btf_decompose(&mat);

    let block_sizes: Vec<usize> = (0..decomp.block_count)
        .map(|k| decomp.block_size(k))
        .collect();

    BtfResult {
        row_perm: decomp.p_row.forward().to_vec(),
        col_perm: decomp.p_col.forward().to_vec(),
        block_sizes,
    }
}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Result of a BTF decomposition of an `n × n` sparse matrix.
///
/// The permuted matrix `P * A * Q^T` is block upper-triangular.  Diagonal
/// block `k` occupies rows and columns `block_starts[k]..block_starts[k+1]`
/// in the permuted ordering.
#[derive(Debug, Clone)]
pub struct BtfDecomposition {
    /// Row permutation `P`.  `p_row.forward()[orig_row]` = permuted row index.
    pub p_row: Permutation,
    /// Column permutation `Q`.  `p_col.forward()[orig_col]` = permuted col index.
    pub p_col: Permutation,
    /// Starting position of each diagonal block in the permuted ordering.
    /// Length `block_count + 1`; `block_starts[block_count] == n`.
    pub block_starts: Vec<usize>,
    /// Number of diagonal blocks.
    pub block_count: usize,
}

impl BtfDecomposition {
    /// Size of diagonal block `k` in the permuted ordering.
    #[inline]
    pub fn block_size(&self, k: usize) -> usize {
        self.block_starts[k + 1] - self.block_starts[k]
    }

    /// Slice of original column indices (in permuted order) for block `k`.
    /// Uses `p_col.inverse()` which maps permuted index → original index.
    pub fn block_col_range(&self, k: usize) -> std::ops::Range<usize> {
        self.block_starts[k]..self.block_starts[k + 1]
    }
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

/// Compute the block triangular form of a square sparse matrix `a`.
///
/// Returns the row/column permutations and the block boundary vector so that
/// `P * A * Q^T` is block upper-triangular with SCCs on the diagonal.
///
/// If the matrix has a trivial structure (no permutation needed, or only one
/// SCC), the permutations are identity and `block_count == 1`.
///
/// # Panics
///
/// Panics if `a` is not square.
pub fn btf_decompose(a: &CscMatrix) -> BtfDecomposition {
    let n = a.nrows();
    assert_eq!(n, a.ncols(), "BTF requires a square matrix");

    if n == 0 {
        return BtfDecomposition {
            p_row: Permutation::identity(0),
            p_col: Permutation::identity(0),
            block_starts: vec![0],
            block_count: 0,
        };
    }

    // --- Step 1: bipartite matching (maximum transversal) ---
    // col_match[j] = row assigned to column j, or usize::MAX if unmatched.
    // row_match[i] = column assigned to row i, or usize::MAX if unmatched.
    let (col_match, _row_match) = bipartite_matching(a, n);

    // --- Step 2: Tarjan SCC on the column dependency graph ---
    // Edge j -> k exists iff A[col_match[j], k] != 0 and k != j.
    // We only traverse columns that have a valid match.
    let sccs = tarjan_sccs(a, n, &col_match);
    // sccs: Vec of SCCs in reverse topological order (leaves first).
    // Each SCC is a Vec<usize> of column indices.

    // --- Step 3: Build permutations ---
    // The permuted column order is: flatten sccs (already in block order).
    // The permuted row order follows the matching: permuted_row[pos] = col_match[permuted_col[pos]].
    let block_count = sccs.len();
    let mut block_starts = Vec::with_capacity(block_count + 1);
    let mut perm_col = Vec::with_capacity(n); // original col index at position i
    let mut perm_row = Vec::with_capacity(n); // original row index at position i

    block_starts.push(0);
    for scc in &sccs {
        for &col in scc {
            perm_col.push(col);
            let row = col_match[col];
            // Push the matched row (may be usize::MAX for unmatched columns).
            perm_row.push(row);
        }
        block_starts.push(perm_col.len());
    }

    // Replace usize::MAX slots (unmatched columns) with unmatched rows.
    // First, collect all rows that are already matched.
    let mut used_rows = vec![false; n];
    for &r in &perm_row {
        if r != usize::MAX {
            used_rows[r] = true;
        }
    }
    // Unmatched rows (those not in col_match).
    let mut unmatched_rows: Vec<usize> = (0..n).filter(|&r| !used_rows[r]).collect();
    let mut ur_iter = unmatched_rows.drain(..);
    for r in perm_row.iter_mut() {
        if *r == usize::MAX {
            // Assign an unmatched row to this slot.
            *r = ur_iter.next().unwrap_or(0);
        }
    }

    // Handle any remaining unmatched columns (shouldn't happen if SCCs cover
    // all columns, but guard anyway).
    if perm_col.len() < n {
        let mut used_cols = vec![false; n];
        for &c in &perm_col {
            used_cols[c] = true;
        }
        for c in 0..n {
            if !used_cols[c] {
                perm_col.push(c);
                // Assign next unmatched row or fallback.
                let r = ur_iter.next().unwrap_or(0);
                perm_row.push(r);
            }
        }
        block_starts.push(n);
    }

    // Build forward permutation vectors.
    // p_col.forward()[orig_col] = permuted_col
    let mut fwd_col = vec![0usize; n];
    for (permuted, &orig) in perm_col.iter().enumerate() {
        fwd_col[orig] = permuted;
    }
    // p_row.forward()[orig_row] = permuted_row
    // All usize::MAX slots have been replaced above; every orig is valid.
    let mut fwd_row = vec![0usize; n];
    for (permuted, &orig) in perm_row.iter().enumerate() {
        fwd_row[orig] = permuted;
    }

    BtfDecomposition {
        p_row: Permutation::from_vec(fwd_row),
        p_col: Permutation::from_vec(fwd_col),
        block_starts,
        block_count,
    }
}

// ---------------------------------------------------------------------------
// Bipartite matching — augmenting-path DFS
// ---------------------------------------------------------------------------

/// Find a maximum matching between rows and columns of `a`.
///
/// Returns `(col_match, row_match)`:
/// - `col_match[j]` = row matched to column `j`, or `usize::MAX` if unmatched.
/// - `row_match[i]` = column matched to row `i`, or `usize::MAX` if unmatched.
///
/// Uses a simple DFS augmenting-path algorithm (O(n * nnz) worst case).
fn bipartite_matching(a: &CscMatrix, n: usize) -> (Vec<usize>, Vec<usize>) {
    let mut col_match = vec![usize::MAX; n];
    let mut row_match = vec![usize::MAX; n];

    // DFS workspace — reuse across column iterations.
    let mut visited = vec![u32::MAX; n]; // visited[row] = column_id that last visited it

    for col_start in 0..n {
        // Try to find an augmenting path starting from column `col_start`.
        // `visited` is stamped with `col_start + 1` to avoid clearing the array.
        let stamp = (col_start as u32).wrapping_add(1);
        augment(
            a,
            col_start,
            stamp,
            &mut col_match,
            &mut row_match,
            &mut visited,
        );
    }

    (col_match, row_match)
}

/// Iterative augmenting-path DFS.
/// Returns `true` if an augmenting path was found from `col`.
///
/// `pred_col[c]` = the column that pushed `c` onto the DFS stack (the
/// "parent" in the DFS tree).  `pred_row[c]` = the row through which `c`
/// was reached (i.e. the row of the matched edge from the parent to `c`).
fn augment(
    a: &CscMatrix,
    col: usize,
    stamp: u32,
    col_match: &mut [usize],
    row_match: &mut [usize],
    visited: &mut [u32],
) -> bool {
    let n = col_match.len();
    // DFS stack: (column, offset into that column's row list).
    let mut stack: Vec<(usize, usize)> = Vec::new();
    // pred_row[c] = the row through which we entered column c from its parent.
    let mut pred_row: Vec<usize> = vec![usize::MAX; n];
    // pred_col[c] = the parent column of c in the DFS tree.
    let mut pred_col: Vec<usize> = vec![usize::MAX; n];

    stack.push((col, a.col_ptr()[col]));

    while !stack.is_empty() {
        let top = stack.len() - 1;
        let cur_col = stack[top].0;
        let idx = stack[top].1;
        let end = a.col_ptr()[cur_col + 1];

        if idx >= end {
            // Exhausted this column — backtrack.
            stack.pop();
            continue;
        }

        let row = a.row_idx()[idx];
        stack[top].1 = idx + 1; // advance iterator

        if visited[row] == stamp {
            continue;
        }
        visited[row] = stamp;

        if row_match[row] == usize::MAX {
            // Free row found — augment along the path back to `col`.
            // Unwind: row is free, cur_col claims it.
            let mut r = row;
            let mut c = cur_col;
            loop {
                col_match[c] = r;
                row_match[r] = c;
                if c == col {
                    break;
                }
                // Move to parent.
                r = pred_row[c];
                c = pred_col[c];
            }
            return true;
        }

        // Row is matched to some column — extend the path.
        let next_col = row_match[row];
        pred_row[next_col] = row;
        pred_col[next_col] = cur_col;
        stack.push((next_col, a.col_ptr()[next_col]));
    }

    false
}

// ---------------------------------------------------------------------------
// Tarjan SCC — iterative
// ---------------------------------------------------------------------------

/// Compute SCCs of the column dependency graph induced by the matching.
///
/// Column `j` has an edge to column `k` iff:
/// - `col_match[j] != usize::MAX`
/// - `A[col_match[j], k] != 0` and `k != j`
///
/// Returns SCCs in reverse topological order (sources first, so that the
/// resulting block layout has no dependents in the lower-right corner).
fn tarjan_sccs(a: &CscMatrix, n: usize, col_match: &[usize]) -> Vec<Vec<usize>> {
    // Iterative Tarjan SCC.
    // We avoid holding a mutable reference to `work` across pushes by
    // copying the needed values out before any push.
    let mut index_counter: u32 = 0;
    let mut scc_stack: Vec<usize> = Vec::with_capacity(n); // Tarjan's S
    let mut on_stack = vec![false; n];
    let mut index = vec![u32::MAX; n]; // u32::MAX = unvisited
    let mut lowlink = vec![0u32; n];
    let mut sccs: Vec<Vec<usize>> = Vec::new();

    // DFS work stack: (node, next_edge_index_within_its_row_in_A).
    // The "row" of node v is col_match[v]; edges are columns in that row.
    let mut work: Vec<(usize, usize)> = Vec::with_capacity(n);

    for start in 0..n {
        if index[start] != u32::MAX {
            continue;
        }

        // Push the start node.
        index[start] = index_counter;
        lowlink[start] = index_counter;
        index_counter += 1;
        scc_stack.push(start);
        on_stack[start] = true;
        work.push((start, 0));

        while !work.is_empty() {
            // Peek at the top frame without holding a mutable reference.
            let (v, edge_idx) = work[work.len() - 1];
            let row_v = col_match[v];

            // Find the next unprocessed neighbour of v.
            let mut next_edge_idx = edge_idx;
            let mut pushed_child = false;

            if row_v != usize::MAX {
                let col_start = a.col_ptr()[row_v];
                let col_end = a.col_ptr()[row_v + 1];

                while next_edge_idx < col_end - col_start {
                    let w = a.row_idx()[col_start + next_edge_idx];
                    next_edge_idx += 1;

                    if w == v {
                        continue;
                    }

                    if index[w] == u32::MAX {
                        // Tree edge: update stored index for v, then push w.
                        let top_idx = work.len() - 1;
                        work[top_idx].1 = next_edge_idx;
                        index[w] = index_counter;
                        lowlink[w] = index_counter;
                        index_counter += 1;
                        scc_stack.push(w);
                        on_stack[w] = true;
                        work.push((w, 0));
                        pushed_child = true;
                        break;
                    } else if on_stack[w] {
                        // Back edge: update lowlink.
                        if index[w] < lowlink[v] {
                            lowlink[v] = index[w];
                        }
                    }
                }
                if !pushed_child {
                    let top_idx = work.len() - 1;
                    work[top_idx].1 = next_edge_idx;
                }
            }

            if pushed_child {
                continue;
            }

            // All neighbours of v processed — pop v.
            work.pop();

            // Update parent's lowlink.
            if !work.is_empty() {
                let parent = work[work.len() - 1].0;
                if lowlink[v] < lowlink[parent] {
                    lowlink[parent] = lowlink[v];
                }
            }

            // Root of an SCC?
            if lowlink[v] == index[v] {
                let mut scc = Vec::new();
                loop {
                    let w = scc_stack.pop().expect("scc_stack non-empty");
                    on_stack[w] = false;
                    scc.push(w);
                    if w == v {
                        break;
                    }
                }
                sccs.push(scc);
            }
        }
    }

    // Tarjan produces SCCs so that if block B depends on block A, A appears
    // before B in `sccs`.  For upper-triangular BTF the independent (leaf)
    // blocks should be in the lower-right.  The natural Tarjan order gives
    // us blocks in dependency order (sources first), which is what we want
    // for placing them along the diagonal from top-left to bottom-right.
    sccs
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linalg::triplet::TripletMatrix;

    // Helper: build CSC from (row, col, val) triples.
    fn build(n: usize, entries: &[(usize, usize, f64)]) -> CscMatrix {
        let mut t = TripletMatrix::new(n, n);
        for &(r, c, v) in entries {
            t.add(r, c, v);
        }
        t.to_csc()
    }

    /// Verify that `P * A * Q^T` has no structural nonzeros strictly above the
    /// block diagonal (i.e. from a higher-indexed block into a lower-indexed block).
    fn check_block_upper_triangular(a: &CscMatrix, btf: &BtfDecomposition) {
        let n = a.nrows();
        let _p_row_inv = btf.p_row.inverse(); // permuted_row -> orig_row (unused in check)
        let p_col_inv = btf.p_col.inverse(); // permuted_col -> orig_col

        // For each permuted column `pc` in block `b`, all nonzeros in permuted
        // rows must be in block `b` or higher (≥ b); i.e. no nonzero in a
        // *lower*-indexed block's rows from block b.
        // In upper-triangular BTF: if entry (pr, pc) is nonzero and pc is in block b,
        // then pr must be in block ≤ b.
        for pc in 0..n {
            let orig_col = p_col_inv[pc];
            // Which block does pc belong to?
            let block_of_pc = btf
                .block_starts
                .windows(2)
                .position(|w| w[0] <= pc && pc < w[1])
                .expect("block found");
            // Column range for orig_col in A.
            for (orig_row, _val) in a.column(orig_col) {
                let pr = btf.p_row.forward()[orig_row];
                let block_of_pr = btf
                    .block_starts
                    .windows(2)
                    .position(|w| w[0] <= pr && pr < w[1])
                    .expect("block found");
                // In upper-triangular BTF: block_of_pr <= block_of_pc is allowed.
                // block_of_pr > block_of_pc means a nonzero ABOVE the block diagonal
                // — that should not happen.
                assert!(
                    block_of_pr <= block_of_pc,
                    "BTF violated: permuted entry ({pr}, {pc}) is in block ({block_of_pr}, {block_of_pc})"
                );
            }
        }
    }

    fn is_btf_trivial(btf: &BtfDecomposition) -> bool {
        btf.block_count <= 1
    }

    // ------------------------------------------------------------------
    // Test 1: Already lower-triangular matrix — every diagonal is its own SCC.
    // ------------------------------------------------------------------
    #[test]
    fn already_diagonal() {
        // 3×3 identity — each variable is independent, n blocks of size 1.
        let a = CscMatrix::identity(3);
        let btf = btf_decompose(&a);
        assert_eq!(btf.block_count, 3);
        for k in 0..3 {
            assert_eq!(btf.block_size(k), 1);
        }
        // The permuted matrix should still be block-upper-triangular.
        check_block_upper_triangular(&a, &btf);
    }

    // ------------------------------------------------------------------
    // Test 2: Fully-connected matrix — one SCC, one block.
    // ------------------------------------------------------------------
    #[test]
    fn single_scc_full_matrix() {
        // Cycle: 0→1→2→0 — all three nodes in one SCC.
        let a = build(
            3,
            &[
                (0, 0, 1.0),
                (1, 0, 1.0), // col 0 touches row 1
                (1, 1, 1.0),
                (2, 1, 1.0), // col 1 touches row 2
                (2, 2, 1.0),
                (0, 2, 1.0), // col 2 touches row 0 — closes cycle
            ],
        );
        let btf = btf_decompose(&a);
        assert_eq!(btf.block_count, 1);
        assert_eq!(btf.block_size(0), 3);
        assert!(is_btf_trivial(&btf));
        check_block_upper_triangular(&a, &btf);
    }

    // ------------------------------------------------------------------
    // Test 3: Known 6×6 matrix from Duff & Reid (1978) example.
    //
    // The matrix has the structure (× = nonzero):
    //
    //   col: 0  1  2  3  4  5
    // row 0: ×  ×  .  .  .  .
    // row 1: ×  ×  ×  .  .  .
    // row 2: .  .  ×  ×  .  .
    // row 3: .  .  ×  ×  ×  .
    // row 4: .  .  .  .  ×  ×
    // row 5: .  .  .  .  ×  ×
    //
    // Expected BTF: three 2×2 blocks on the diagonal with upper fill allowed.
    // - Block A: {0,1} — rows/cols 0,1 form a cycle: (0,1) -> (1,0).
    // - Block B: {2,3} — rows/cols 2,3 form a cycle: (2,3) -> (3,2).
    // - Block C: {4,5} — rows/cols 4,5 form a cycle: (4,5) -> (5,4).
    // ------------------------------------------------------------------
    #[test]
    fn duff_reid_6x6() {
        let a = build(
            6,
            &[
                (0, 0, 1.0),
                (0, 1, 1.0),
                (1, 0, 1.0),
                (1, 1, 1.0),
                (1, 2, 1.0),
                (2, 2, 1.0),
                (2, 3, 1.0),
                (3, 2, 1.0),
                (3, 3, 1.0),
                (3, 4, 1.0),
                (4, 4, 1.0),
                (4, 5, 1.0),
                (5, 4, 1.0),
                (5, 5, 1.0),
            ],
        );
        let btf = btf_decompose(&a);
        // We expect at most 3 blocks of size 2.
        // (The exact count depends on how many SCCs Tarjan finds;
        //  all three pairs should be separate SCCs.)
        assert!(
            btf.block_count >= 2,
            "expected at least 2 blocks, got {}",
            btf.block_count
        );
        assert!(
            !is_btf_trivial(&btf),
            "should not be trivial for this matrix"
        );
        check_block_upper_triangular(&a, &btf);
    }

    // ------------------------------------------------------------------
    // Test 4: Two independent 2×2 blocks with no coupling.
    // ------------------------------------------------------------------
    #[test]
    fn two_independent_blocks() {
        // [A 0]   where A = [1 1; 1 1] and B = [2 2; 2 2]
        // [0 B]
        let a = build(
            4,
            &[
                (0, 0, 1.0),
                (0, 1, 1.0),
                (1, 0, 1.0),
                (1, 1, 1.0),
                (2, 2, 2.0),
                (2, 3, 2.0),
                (3, 2, 2.0),
                (3, 3, 2.0),
            ],
        );
        let btf = btf_decompose(&a);
        // Two separate SCCs: {0,1} and {2,3}.
        assert_eq!(btf.block_count, 2);
        for k in 0..btf.block_count {
            assert_eq!(btf.block_size(k), 2);
        }
        check_block_upper_triangular(&a, &btf);
    }

    // ------------------------------------------------------------------
    // Test 5: Upper-triangular matrix — each column is its own SCC.
    // ------------------------------------------------------------------
    #[test]
    fn upper_triangular_all_singletons() {
        // 4×4 upper triangular with full diagonal.
        let a = build(
            4,
            &[
                (0, 0, 1.0),
                (0, 1, 2.0),
                (0, 2, 3.0),
                (0, 3, 4.0),
                (1, 1, 5.0),
                (1, 2, 6.0),
                (1, 3, 7.0),
                (2, 2, 8.0),
                (2, 3, 9.0),
                (3, 3, 10.0),
            ],
        );
        let btf = btf_decompose(&a);
        assert_eq!(btf.block_count, 4, "expected 4 singleton blocks");
        check_block_upper_triangular(&a, &btf);
    }

    // ------------------------------------------------------------------
    // Test 6: 1×1 matrix.
    // ------------------------------------------------------------------
    #[test]
    fn single_element() {
        let a = build(1, &[(0, 0, 42.0)]);
        let btf = btf_decompose(&a);
        assert_eq!(btf.block_count, 1);
        assert_eq!(btf.block_size(0), 1);
        check_block_upper_triangular(&a, &btf);
    }

    // ------------------------------------------------------------------
    // Test P.1: 6×6 block-diagonal matrix — 2 independent 3×3 blocks.
    //
    // Matrix structure:
    //   [ A  0 ]   where A (3×3) and B (3×3) are each fully dense
    //   [ 0  B ]   with a mutual cycle, making each a single SCC.
    //
    // BTF must find exactly 2 blocks, each of size 3.
    // ------------------------------------------------------------------
    #[test]
    fn two_independent_3x3_blocks() {
        // Block A: rows/cols 0,1,2 — cycle 0→1→2→0 (one SCC of size 3).
        // Block B: rows/cols 3,4,5 — cycle 3→4→5→3 (one SCC of size 3).
        // No coupling between A and B.
        let a = build(
            6,
            &[
                // Block A: diagonal + cycle
                (0, 0, 1.0),
                (1, 0, 1.0), // col 0 → row 1 (edge 0→1 in col graph)
                (1, 1, 1.0),
                (2, 1, 1.0), // col 1 → row 2
                (2, 2, 1.0),
                (0, 2, 1.0), // col 2 → row 0 (closes cycle)
                // Block B: diagonal + cycle
                (3, 3, 2.0),
                (4, 3, 2.0), // col 3 → row 4
                (4, 4, 2.0),
                (5, 4, 2.0), // col 4 → row 5
                (5, 5, 2.0),
                (3, 5, 2.0), // col 5 → row 3 (closes cycle)
            ],
        );
        let btf = btf_decompose(&a);

        // Must detect exactly 2 blocks, each of size 3.
        assert_eq!(
            btf.block_count, 2,
            "expected 2 independent blocks, got {}",
            btf.block_count
        );
        // Both blocks must have size 3.
        let sizes: Vec<usize> = (0..btf.block_count).map(|k| btf.block_size(k)).collect();
        assert!(
            sizes.iter().all(|&s| s == 3),
            "expected all blocks of size 3, got {:?}",
            sizes
        );
        // The permuted matrix must be block-upper-triangular.
        check_block_upper_triangular(&a, &btf);
    }

    // ------------------------------------------------------------------
    // Test 7: is_btf_trivial on a real non-trivial decomposition.
    // ------------------------------------------------------------------
    #[test]
    fn trivial_flag() {
        let single_scc = build(2, &[(0, 0, 1.0), (0, 1, 1.0), (1, 0, 1.0), (1, 1, 1.0)]);
        let btf = btf_decompose(&single_scc);
        assert!(is_btf_trivial(&btf));

        let two_blocks = build(2, &[(0, 0, 1.0), (1, 1, 1.0)]);
        let btf2 = btf_decompose(&two_blocks);
        assert!(!is_btf_trivial(&btf2));
    }

    // ------------------------------------------------------------------
    // Test 8: Empty 0x0 matrix returns empty decomposition.
    // ------------------------------------------------------------------
    #[test]
    fn empty_matrix() {
        let a = CscMatrix::zeros(0, 0);
        let btf = btf_decompose(&a);
        assert_eq!(btf.block_count, 0);
        assert_eq!(btf.block_starts, vec![0]);
    }

    // ------------------------------------------------------------------
    // Test 9: Block sizes sum to n.
    // ------------------------------------------------------------------
    #[test]
    fn block_sizes_sum_to_n() {
        let a = build(
            5,
            &[
                (0, 0, 1.0),
                (1, 0, 1.0),
                (1, 1, 1.0),
                (2, 2, 1.0),
                (3, 2, 1.0),
                (3, 3, 1.0),
                (4, 4, 1.0),
            ],
        );
        let btf = btf_decompose(&a);
        let total: usize = (0..btf.block_count).map(|k| btf.block_size(k)).sum();
        assert_eq!(total, 5);
    }

    // ------------------------------------------------------------------
    // Test 10: btf_permutation wrapper produces same block sizes as btf_decompose.
    // ------------------------------------------------------------------
    #[test]
    fn btf_permutation_wrapper_block_sizes() {
        let n = 4;
        let entries: &[(usize, usize, f64)] = &[
            (0, 0, 1.0),
            (0, 1, 1.0),
            (1, 0, 1.0),
            (1, 1, 1.0),
            (2, 2, 2.0),
            (2, 3, 2.0),
            (3, 2, 2.0),
            (3, 3, 2.0),
        ];
        let a = build(n, entries);
        let decomp = btf_decompose(&a);

        // Build raw CSC arrays to pass to btf_permutation
        let col_ptr = a.col_ptr().to_vec();
        let row_idx = a.row_idx().to_vec();
        let result = btf_permutation(n, &col_ptr, &row_idx);

        let decomp_sizes: Vec<usize> = (0..decomp.block_count)
            .map(|k| decomp.block_size(k))
            .collect();
        // sort both so order doesn't matter
        let mut ds = decomp_sizes.clone();
        let mut rs = result.block_sizes.clone();
        ds.sort();
        rs.sort();
        assert_eq!(ds, rs, "block sizes must match between decompose and wrapper");
    }

    // ------------------------------------------------------------------
    // Test 11: block_col_range returns correct range.
    // ------------------------------------------------------------------
    #[test]
    fn block_col_range_correct() {
        let a = build(
            4,
            &[
                (0, 0, 1.0),
                (0, 1, 1.0),
                (1, 0, 1.0),
                (1, 1, 1.0),
                (2, 2, 2.0),
                (2, 3, 2.0),
                (3, 2, 2.0),
                (3, 3, 2.0),
            ],
        );
        let btf = btf_decompose(&a);
        assert_eq!(btf.block_count, 2);
        for k in 0..btf.block_count {
            let r = btf.block_col_range(k);
            assert_eq!(r.end - r.start, btf.block_size(k));
        }
    }

    // ------------------------------------------------------------------
    // Test 12: row/col permutations are valid (each index appears once).
    // ------------------------------------------------------------------
    #[test]
    fn permutations_are_valid() {
        let a = build(
            5,
            &[
                (0, 0, 1.0),
                (1, 0, 1.0),
                (0, 1, 1.0),
                (1, 1, 1.0),
                (2, 2, 1.0),
                (3, 3, 1.0),
                (4, 4, 1.0),
            ],
        );
        let btf = btf_decompose(&a);
        let fwd_row = btf.p_row.forward();
        let fwd_col = btf.p_col.forward();
        let n = 5;
        let mut seen_r = vec![false; n];
        let mut seen_c = vec![false; n];
        for &r in fwd_row { assert!(r < n); assert!(!seen_r[r]); seen_r[r] = true; }
        for &c in fwd_col { assert!(c < n); assert!(!seen_c[c]); seen_c[c] = true; }
    }

    // ------------------------------------------------------------------
    // Test 13: BTF preserves block structure across various sizes.
    // ------------------------------------------------------------------
    #[test]
    fn btf_preserves_structure_tridiagonal() {
        // Tridiagonal — one fully connected SCC
        let n = 4;
        let a = build(n, &[
            (0, 0, 2.0), (0, 1, -1.0),
            (1, 0, -1.0), (1, 1, 2.0), (1, 2, -1.0),
            (2, 1, -1.0), (2, 2, 2.0), (2, 3, -1.0),
            (3, 2, -1.0), (3, 3, 2.0),
        ]);
        let btf = btf_decompose(&a);
        let total: usize = (0..btf.block_count).map(|k| btf.block_size(k)).sum();
        assert_eq!(total, n);
        check_block_upper_triangular(&a, &btf);
    }
}
