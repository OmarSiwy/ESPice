use std::ops::{Index, IndexMut, Add, Sub, Mul};

/// A dense vector of `f64` values backed by a contiguous `Vec<f64>`.
///
/// Provides BLAS-like primitives (axpy, dot, norms, scale) used throughout
/// the sparse solver pipeline.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct DenseVec {
    data: Vec<f64>,
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

impl DenseVec {
    /// Create an uninitialised vector of length `n` (all zeros).
    #[inline]
    pub fn new(n: usize) -> Self {
        Self::zeros(n)
    }

    /// Create a zero-filled vector of length `n`.
    #[inline]
    pub fn zeros(n: usize) -> Self {
        Self { data: vec![0.0; n] }
    }

    /// Create a `DenseVec` by copying the given slice.
    #[inline]
    pub fn from_slice(s: &[f64]) -> Self {
        Self { data: s.to_vec() }
    }

    /// Number of elements.
    #[inline]
    pub fn len(&self) -> usize {
        self.data.len()
    }

    /// Whether the vector is empty.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// Immutable access to the underlying slice.
    #[inline]
    pub fn as_slice(&self) -> &[f64] {
        &self.data
    }

    /// Mutable access to the underlying slice.
    #[inline]
    pub fn as_mut_slice(&mut self) -> &mut [f64] {
        &mut self.data
    }
}

// ---------------------------------------------------------------------------
// Numeric operations
// ---------------------------------------------------------------------------

impl DenseVec {
    /// Infinity norm: max |x_i|.
    #[inline]
    pub fn norm_inf(&self) -> f64 {
        self.data
            .iter()
            .fold(0.0_f64, |acc, &v| acc.max(v.abs()))
    }

    /// Euclidean (L2) norm: sqrt(sum x_i^2).
    #[inline]
    pub fn norm2(&self) -> f64 {
        self.data.iter().map(|&v| v * v).sum::<f64>().sqrt()
    }

    /// AXPY: `self += a * x`.  Panics if lengths differ.
    #[inline]
    pub fn axpy(&mut self, a: f64, x: &DenseVec) {
        assert_eq!(self.len(), x.len(), "axpy: length mismatch");
        for (si, &xi) in self.data.iter_mut().zip(x.data.iter()) {
            *si += a * xi;
        }
    }

    /// Dot product: sum(self_i * other_i).  Panics if lengths differ.
    #[inline]
    pub fn dot(&self, other: &DenseVec) -> f64 {
        assert_eq!(self.len(), other.len(), "dot: length mismatch");
        self.data
            .iter()
            .zip(other.data.iter())
            .map(|(&a, &b)| a * b)
            .sum()
    }

    /// Scale every element by `a`.
    #[inline]
    pub fn scale(&mut self, a: f64) {
        for v in &mut self.data {
            *v *= a;
        }
    }

    /// Set all entries to zero without reallocating.
    #[inline]
    pub fn fill_zero(&mut self) {
        self.data.fill(0.0);
    }
}

// ---------------------------------------------------------------------------
// Indexing
// ---------------------------------------------------------------------------

impl Index<usize> for DenseVec {
    type Output = f64;
    #[inline]
    fn index(&self, i: usize) -> &f64 {
        &self.data[i]
    }
}

impl IndexMut<usize> for DenseVec {
    #[inline]
    fn index_mut(&mut self, i: usize) -> &mut f64 {
        &mut self.data[i]
    }
}

// ---------------------------------------------------------------------------
// Operator overloads (consuming, produce new vec)
// ---------------------------------------------------------------------------

impl Add for &DenseVec {
    type Output = DenseVec;
    fn add(self, rhs: &DenseVec) -> DenseVec {
        assert_eq!(self.len(), rhs.len());
        let data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(&a, &b)| a + b)
            .collect();
        DenseVec { data }
    }
}

impl Sub for &DenseVec {
    type Output = DenseVec;
    fn sub(self, rhs: &DenseVec) -> DenseVec {
        assert_eq!(self.len(), rhs.len());
        let data = self
            .data
            .iter()
            .zip(rhs.data.iter())
            .map(|(&a, &b)| a - b)
            .collect();
        DenseVec { data }
    }
}

impl Mul<f64> for &DenseVec {
    type Output = DenseVec;
    fn mul(self, scalar: f64) -> DenseVec {
        let data = self.data.iter().map(|&v| v * scalar).collect();
        DenseVec { data }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_and_zeros() {
        let v = DenseVec::new(5);
        assert_eq!(v.len(), 5);
        for i in 0..5 {
            assert_eq!(v[i], 0.0);
        }
    }

    #[test]
    fn test_from_slice() {
        let v = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        assert_eq!(v.len(), 3);
        assert_eq!(v[0], 1.0);
        assert_eq!(v[2], 3.0);
    }

    #[test]
    fn test_norm_inf() {
        let v = DenseVec::from_slice(&[-5.0, 3.0, 1.0]);
        assert_eq!(v.norm_inf(), 5.0);
    }

    #[test]
    fn test_norm2() {
        let v = DenseVec::from_slice(&[3.0, 4.0]);
        assert!((v.norm2() - 5.0).abs() < 1e-14);
    }

    #[test]
    fn test_axpy() {
        let mut y = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let x = DenseVec::from_slice(&[10.0, 20.0, 30.0]);
        y.axpy(0.5, &x);
        assert_eq!(y[0], 6.0);
        assert_eq!(y[1], 12.0);
        assert_eq!(y[2], 18.0);
    }

    #[test]
    fn test_dot() {
        let a = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        let b = DenseVec::from_slice(&[4.0, 5.0, 6.0]);
        assert!((a.dot(&b) - 32.0).abs() < 1e-14);
    }

    #[test]
    fn test_scale() {
        let mut v = DenseVec::from_slice(&[1.0, -2.0, 3.0]);
        v.scale(2.0);
        assert_eq!(v[0], 2.0);
        assert_eq!(v[1], -4.0);
        assert_eq!(v[2], 6.0);
    }

    #[test]
    fn test_add_sub_mul() {
        let a = DenseVec::from_slice(&[1.0, 2.0]);
        let b = DenseVec::from_slice(&[3.0, 4.0]);
        let c = &a + &b;
        assert_eq!(c[0], 4.0);
        assert_eq!(c[1], 6.0);

        let d = &a - &b;
        assert_eq!(d[0], -2.0);
        assert_eq!(d[1], -2.0);

        let e = &a * 3.0;
        assert_eq!(e[0], 3.0);
        assert_eq!(e[1], 6.0);
    }

    #[test]
    fn test_index_mut() {
        let mut v = DenseVec::zeros(3);
        v[1] = 42.0;
        assert_eq!(v[1], 42.0);
    }

    #[test]
    fn test_fill_zero() {
        let mut v = DenseVec::from_slice(&[1.0, 2.0, 3.0]);
        v.fill_zero();
        assert_eq!(v.norm_inf(), 0.0);
    }

    #[test]
    fn test_empty_vec() {
        let v = DenseVec::new(0);
        assert!(v.is_empty());
        assert_eq!(v.norm2(), 0.0);
        assert_eq!(v.norm_inf(), 0.0);
    }
}
