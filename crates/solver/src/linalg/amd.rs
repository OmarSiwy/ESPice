//! Simple Approximate Minimum Degree (AMD) ordering on the symmetric
//! pattern of `A + A^T`.
//!
//! This is a deliberately straightforward implementation: at each step we
//! pick the vertex of minimum current degree, eliminate it, and update its
//! neighbours' adjacency lists by merging.  No element absorption, no
//! mass elimination, no aggressive supervariable detection.  These are
//! the optimisations that distinguish a "real" AMD (Amestoy/Davis/Duff
//! 1996) from this baseline, but for typical SPICE matrices (a few
//! hundred to a few thousand nodes) the simple version already cuts
//! fill-in by a large factor versus the natural ordering.
//!
//! For very large matrices (> 10k nodes) this should be replaced with a
//! proper AMD or COLAMD implementation.

use super::csc::CscMatrix;
use super::permutation::Permutation;
use std::collections::BTreeSet;

/// Compute a fill-reducing column ordering for `a` using minimum degree on
/// the symmetric pattern `A + A^T`.  Returns a `Permutation` such that
/// `permuted_col_index = perm.forward()[original_col_index]`.
pub fn amd_order(a: &CscMatrix) -> Permutation {
    let n = a.ncols();
    assert_eq!(n, a.nrows(), "amd_order requires a square matrix");

    if n <= 1 {
        return Permutation::identity(n);
    }

    // Build adjacency sets for the symmetric pattern.
    let mut adj: Vec<BTreeSet<u32>> = (0..n).map(|_| BTreeSet::new()).collect();

    for j in 0..n {
        for (i, _) in a.column(j) {
            if i != j {
                adj[i].insert(j as u32);
                adj[j].insert(i as u32);
            }
        }
    }

    let mut alive = vec![true; n];
    let mut order: Vec<usize> = Vec::with_capacity(n);

    for _step in 0..n {
        // Pick the alive vertex of minimum degree (ties broken by index).
        let mut best: i64 = -1;
        let mut best_deg = usize::MAX;
        for v in 0..n {
            if !alive[v] {
                continue;
            }
            let d = adj[v].len();
            if d < best_deg {
                best_deg = d;
                best = v as i64;
                if d == 0 {
                    break;
                }
            }
        }
        if best < 0 {
            break;
        }
        let p = best as usize;
        order.push(p);
        alive[p] = false;

        let nbrs: Vec<u32> = std::mem::take(&mut adj[p]).into_iter().collect();

        for &u in nbrs.iter() {
            adj[u as usize].remove(&(p as u32));
        }

        for i in 0..nbrs.len() {
            let u = nbrs[i] as usize;
            if !alive[u] {
                continue;
            }
            for j in (i + 1)..nbrs.len() {
                let v = nbrs[j] as usize;
                if !alive[v] {
                    continue;
                }
                adj[u].insert(v as u32);
                adj[v].insert(u as u32);
            }
        }
    }

    // `order[k]` = original column that should appear at position k.
    // Build perm such that perm[orig] = k.
    let mut perm = vec![0usize; n];
    for (k, &orig) in order.iter().enumerate() {
        perm[orig] = k;
    }
    Permutation::from_vec(perm)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linalg::triplet::TripletMatrix;

    #[test]
    fn identity_unchanged_size_3() {
        let id = CscMatrix::identity(3);
        let p = amd_order(&id);
        assert_eq!(p.len(), 3);
        let mut seen = [false; 3];
        for &k in p.forward() {
            assert!(k < 3 && !seen[k]);
            seen[k] = true;
        }
    }

    #[test]
    fn arrowhead_defers_apex() {
        let n = 5;
        let mut t = TripletMatrix::new(n, n);
        for i in 0..n {
            t.add(i, i, 1.0);
        }
        for i in 1..n {
            t.add(0, i, 1.0);
            t.add(i, 0, 1.0);
        }
        let a = t.to_csc();
        let p = amd_order(&a);
        let first = p.inverse()[0];
        assert_ne!(
            first,
            0,
            "AMD should not eliminate apex first; perm = {:?}",
            p.forward()
        );
        let pos_of_zero = p.forward()[0];
        assert!(
            pos_of_zero >= n - 2,
            "AMD should defer apex; got pos {} for n={}",
            pos_of_zero,
            n
        );
    }

    #[test]
    fn amd_is_a_valid_permutation() {
        let mut t = TripletMatrix::new(4, 4);
        for i in 0..4 {
            t.add(i, i, 2.0);
        }
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        t.add(2, 3, 1.0);
        t.add(3, 2, 1.0);
        let a = t.to_csc();
        let p = amd_order(&a);
        let fwd = p.forward();
        let mut seen = vec![false; 4];
        for &k in fwd {
            assert!(k < 4);
            assert!(!seen[k]);
            seen[k] = true;
        }
    }

    #[test]
    fn amd_1x1_is_identity() {
        let mut t = TripletMatrix::new(1, 1);
        t.add(0, 0, 5.0);
        let a = t.to_csc();
        let p = amd_order(&a);
        assert_eq!(p.forward(), &[0]);
    }

    #[test]
    fn amd_2x2_dense_is_valid_permutation() {
        let mut t = TripletMatrix::new(2, 2);
        t.add(0, 0, 2.0);
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        t.add(1, 1, 2.0);
        let a = t.to_csc();
        let p = amd_order(&a);
        let fwd = p.forward();
        assert_eq!(fwd.len(), 2);
        let mut seen = [false; 2];
        for &k in fwd {
            assert!(k < 2);
            assert!(!seen[k]);
            seen[k] = true;
        }
    }

    #[test]
    fn amd_diagonal_only_any_order() {
        // Diagonal-only matrix: AMD may produce any permutation (all nodes isolated)
        let n = 5;
        let mut t = TripletMatrix::new(n, n);
        for i in 0..n {
            t.add(i, i, 1.0);
        }
        let a = t.to_csc();
        let p = amd_order(&a);
        let fwd = p.forward();
        let mut seen = vec![false; n];
        for &k in fwd {
            assert!(k < n);
            assert!(!seen[k]);
            seen[k] = true;
        }
    }

    #[test]
    fn amd_chain_graph_is_valid_permutation() {
        // Chain: 0-1-2-3-4 (tridiagonal)
        let n = 5;
        let mut t = TripletMatrix::new(n, n);
        for i in 0..n {
            t.add(i, i, 2.0);
        }
        for i in 0..n - 1 {
            t.add(i, i + 1, -1.0);
            t.add(i + 1, i, -1.0);
        }
        let a = t.to_csc();
        let p = amd_order(&a);
        let fwd = p.forward();
        let mut seen = vec![false; n];
        for &k in fwd {
            assert!(k < n);
            assert!(!seen[k]);
            seen[k] = true;
        }
    }

    #[test]
    fn amd_inverse_consistent_with_forward() {
        let mut t = TripletMatrix::new(4, 4);
        for i in 0..4 {
            t.add(i, i, 3.0);
        }
        t.add(0, 1, 1.0);
        t.add(1, 0, 1.0);
        t.add(1, 2, 1.0);
        t.add(2, 1, 1.0);
        let a = t.to_csc();
        let p = amd_order(&a);
        let fwd = p.forward();
        let inv = p.inverse();
        for (i, &f) in fwd.iter().enumerate() {
            assert_eq!(inv[f], i, "inv[fwd[{i}]] != {i}");
        }
    }
}
