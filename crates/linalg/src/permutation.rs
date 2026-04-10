use crate::dense_vec::DenseVec;

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
    /// `swaps[k] = (i, j)` means swap positions `i` and `j` at step `k`.
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

    /// Swap two positions in the permutation (mutating, used during
    /// factorisation).
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
        // Permutation: 0->2, 1->0, 2->1
        let p = Permutation::from_vec(vec![2, 0, 1]);
        assert_eq!(p.forward(), &[2, 0, 1]);
        // Inverse: position 0 was element 1, position 1 was element 2, position 2 was element 0
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
        // result[2] = v[0]=10, result[0] = v[1]=20, result[1] = v[2]=30
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
        // c[i] = p1[p2[i]]
        // c[0] = p1[2] = 0
        // c[1] = p1[0] = 1
        // c[2] = p1[1] = 2
        assert_eq!(c.forward(), &[0, 1, 2]); // identity!
    }

    #[test]
    fn test_from_swaps() {
        let p = Permutation::from_swaps(3, &[(0, 2), (1, 2)]);
        // Start: [0,1,2] -> swap(0,2) -> [2,1,0] -> swap(1,2) -> [2,0,1]
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
}
