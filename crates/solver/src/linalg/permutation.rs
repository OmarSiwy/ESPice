use super::dense_vec::DenseVec;

/// A permutation of indices `0..n` stored as both the forward map and its
/// inverse.  Used for row / column pivoting in LU factorisation.
#[derive(Debug, Clone, PartialEq)]
pub struct Permutation {
    /// `perm[i]` = position that element `i` maps to.
    perm: Vec<usize>,
    /// `inv[j]` = original element that maps to position `j`.
    inv: Vec<usize>,
}

impl Permutation {
    /// The identity permutation on `0..n`.
    pub fn identity(n: usize) -> Self {
        let perm: Vec<usize> = (0..n).collect();
        let inv = perm.clone();
        Self { perm, inv }
    }

    /// Build from a forward-map vector.  Panics if `perm` is not a valid
    /// permutation of `0..n`.
    pub fn from_vec(perm: Vec<usize>) -> Self {
        let n = perm.len();
        let mut inv = vec![0usize; n];
        let mut seen = vec![false; n];
        for (i, &p) in perm.iter().enumerate() {
            assert!(p < n, "permutation index {p} out of range 0..{n}");
            assert!(!seen[p], "duplicate permutation entry {p}");
            seen[p] = true;
            inv[p] = i;
        }
        Self { perm, inv }
    }

    /// Build from a sequence of pair-swaps applied in order.
    pub fn from_swaps(n: usize, swaps: &[(usize, usize)]) -> Self {
        let mut perm: Vec<usize> = (0..n).collect();
        for &(i, j) in swaps {
            perm.swap(i, j);
        }
        Self::from_vec(perm)
    }

    /// Length of the permutation.
    #[inline]
    pub fn len(&self) -> usize {
        self.perm.len()
    }

    /// Whether the permutation is empty.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.perm.is_empty()
    }

    /// Forward map: element `i` goes to position `perm[i]`.
    #[inline]
    pub fn forward(&self) -> &[usize] {
        &self.perm
    }

    /// Inverse map: position `j` was originally element `inv[j]`.
    #[inline]
    pub fn inverse(&self) -> &[usize] {
        &self.inv
    }

    /// Apply the forward permutation to a dense vector: `result[perm[i]] = v[i]`.
    pub fn apply(&self, v: &DenseVec) -> DenseVec {
        assert_eq!(v.len(), self.len());
        let mut out = DenseVec::zeros(v.len());
        for (i, &p) in self.perm.iter().enumerate() {
            out[p] = v[i];
        }
        out
    }

    /// Apply the inverse permutation: `result[i] = v[perm[i]]`.
    pub fn apply_inv(&self, v: &DenseVec) -> DenseVec {
        assert_eq!(v.len(), self.len());
        let mut out = DenseVec::zeros(v.len());
        for (i, &p) in self.perm.iter().enumerate() {
            out[i] = v[p];
        }
        out
    }

    /// Compose two permutations: `(self ∘ other)[i] = self.perm[other.perm[i]]`.
    pub fn compose(&self, other: &Permutation) -> Permutation {
        assert_eq!(self.len(), other.len());
        let perm: Vec<usize> = other.perm.iter().map(|&i| self.perm[i]).collect();
        Permutation::from_vec(perm)
    }

    /// Swap two positions in the permutation (mutating, used during factorisation).
    pub fn swap(&mut self, i: usize, j: usize) {
        self.perm.swap(i, j);
        let pi = self.perm[i];
        let pj = self.perm[j];
        self.inv[pi] = i;
        self.inv[pj] = j;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_identity() {
        let p = Permutation::identity(4);
        assert_eq!(p.forward(), &[0, 1, 2, 3]);
        assert_eq!(p.inverse(), &[0, 1, 2, 3]);
    }

    #[test]
    fn test_from_vec() {
        let p = Permutation::from_vec(vec![2, 0, 1]);
        assert_eq!(p.forward(), &[2, 0, 1]);
        assert_eq!(p.inverse(), &[1, 2, 0]);
    }

    #[test]
    #[should_panic]
    fn test_invalid_permutation() {
        Permutation::from_vec(vec![0, 0, 1]);
    }

    #[test]
    fn test_apply() {
        let p = Permutation::from_vec(vec![2, 0, 1]);
        let v = DenseVec::from_slice(&[10.0, 20.0, 30.0]);
        let pv = p.apply(&v);
        assert_eq!(pv[0], 20.0);
        assert_eq!(pv[1], 30.0);
        assert_eq!(pv[2], 10.0);
    }

    #[test]
    fn test_apply_inv() {
        let p = Permutation::from_vec(vec![2, 0, 1]);
        let v = DenseVec::from_slice(&[10.0, 20.0, 30.0]);
        let pv = p.apply(&v);
        let recovered = p.apply_inv(&pv);
        for i in 0..3 {
            assert!((recovered[i] - v[i]).abs() < 1e-14);
        }
    }

    #[test]
    fn test_compose() {
        let p1 = Permutation::from_vec(vec![1, 2, 0]);
        let p2 = Permutation::from_vec(vec![2, 0, 1]);
        let c = p1.compose(&p2);
        assert_eq!(c.forward(), &[0, 1, 2]);
    }

    #[test]
    fn test_from_swaps() {
        let p = Permutation::from_swaps(3, &[(0, 2), (1, 2)]);
        assert_eq!(p.forward(), &[2, 0, 1]);
    }

    #[test]
    fn test_identity_apply_is_noop() {
        let p = Permutation::identity(3);
        let v = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let pv = p.apply(&v);
        for i in 0..3 {
            assert_eq!(pv[i], v[i]);
        }
    }

    #[test]
    fn test_swap() {
        let mut p = Permutation::identity(4);
        p.swap(0, 3);
        assert_eq!(p.forward(), &[3, 1, 2, 0]);
        assert_eq!(p.inverse(), &[3, 1, 2, 0]);
    }

    #[test]
    fn test_identity_n0() {
        let p = Permutation::identity(0);
        assert!(p.is_empty());
        assert_eq!(p.len(), 0);
    }

    #[test]
    fn test_identity_n1() {
        let p = Permutation::identity(1);
        assert_eq!(p.forward(), &[0]);
        assert_eq!(p.inverse(), &[0]);
    }

    #[test]
    fn test_compose_with_identity() {
        let p = Permutation::from_vec(vec![2, 0, 1]);
        let id = Permutation::identity(3);
        let c = p.compose(&id);
        assert_eq!(c.forward(), p.forward());
    }

    #[test]
    fn test_compose_is_associative() {
        // p1 ∘ (p2 ∘ p3) == (p1 ∘ p2) ∘ p3
        let p1 = Permutation::from_vec(vec![1, 2, 0]);
        let p2 = Permutation::from_vec(vec![0, 2, 1]);
        let p3 = Permutation::from_vec(vec![2, 0, 1]);
        let left = p1.compose(&p2.compose(&p3));
        let right = p1.compose(&p2).compose(&p3);
        assert_eq!(left.forward(), right.forward());
    }

    #[test]
    fn test_apply_inverse_of_permuted() {
        // apply_inv(apply(v)) == v for any permutation
        let p = Permutation::from_vec(vec![1, 2, 0]);
        let v = DenseVec::from_slice(&[10.0, 20.0, 30.0]);
        let permuted = p.apply(&v);
        let recovered = p.apply_inv(&permuted);
        for i in 0..3 {
            assert!((recovered[i] - v[i]).abs() < 1e-14, "i={i}");
        }
    }

    #[test]
    fn test_from_swaps_empty() {
        let p = Permutation::from_swaps(3, &[]);
        assert_eq!(p.forward(), &[0, 1, 2]);
    }

    #[test]
    fn test_from_swaps_double_swap_is_identity() {
        // Swapping (0,1) twice should restore identity
        let p = Permutation::from_swaps(3, &[(0, 1), (0, 1)]);
        assert_eq!(p.forward(), &[0, 1, 2]);
    }

    #[test]
    fn test_multiple_swaps_correct() {
        let p = Permutation::from_swaps(4, &[(0, 3)]);
        assert_eq!(p.forward()[0], 3);
        assert_eq!(p.forward()[3], 0);
        assert_eq!(p.forward()[1], 1);
        assert_eq!(p.forward()[2], 2);
    }

    #[test]
    fn test_inverse_is_self_for_involution() {
        // Swap-based permutation [1, 0, 2] is its own inverse
        let p = Permutation::from_vec(vec![1, 0, 2]);
        assert_eq!(p.forward(), p.inverse());
    }

    #[test]
    fn test_forward_and_inverse_are_consistent() {
        let p = Permutation::from_vec(vec![3, 1, 0, 2]);
        let fwd = p.forward();
        let inv = p.inverse();
        // For all i: inv[fwd[i]] == i
        for (i, &f) in fwd.iter().enumerate() {
            assert_eq!(inv[f], i);
        }
    }

    #[test]
    fn test_swap_preserves_validity() {
        let mut p = Permutation::identity(5);
        p.swap(2, 4);
        // Verify forward/inverse consistency
        let fwd = p.forward().to_vec();
        let inv = p.inverse().to_vec();
        for (i, &f) in fwd.iter().enumerate() {
            assert_eq!(inv[f], i, "inv[fwd[{i}]] != {i}");
        }
    }
}
