/// Fixed-size, cache-line-aligned block of `f64` values with batch operations.
///
/// Stores exactly `N` values in a flat array. Operations process elements
/// in tight loops that the compiler can auto-vectorize.
#[derive(Clone)]
#[repr(align(64))]
pub struct SimdBlock<const N: usize> {
    pub data: [f64; N],
}

impl<const N: usize> SimdBlock<N> {
    pub fn zeros() -> Self {
        Self { data: [0.0; N] }
    }

    pub fn splat(val: f64) -> Self {
        Self { data: [val; N] }
    }

    pub fn from_slice(src: &[f64]) -> Self {
        assert!(src.len() >= N, "source slice too short");
        let mut data = [0.0; N];
        data.copy_from_slice(&src[..N]);
        Self { data }
    }

    #[inline]
    pub fn as_slice(&self) -> &[f64] {
        &self.data
    }

    #[inline]
    pub fn as_mut_slice(&mut self) -> &mut [f64] {
        &mut self.data
    }

    /// `self[i] += alpha * other[i]`.
    pub fn axpy(&mut self, alpha: f64, other: &Self) {
        self.data.iter_mut()
            .zip(other.data.iter())
            .for_each(|(a, &b)| *a += alpha * b);
    }

    /// `self[i] *= alpha`.
    pub fn scale(&mut self, alpha: f64) {
        self.data.iter_mut().for_each(|v| *v *= alpha);
    }

    /// Dot product: `sum(self[i] * other[i])`.
    pub fn dot(&self, other: &Self) -> f64 {
        self.data.iter()
            .zip(other.data.iter())
            .map(|(&a, &b)| a * b)
            .sum()
    }

    /// Infinity norm: `max(|self[i]|)`.
    pub fn norm_inf(&self) -> f64 {
        self.data.iter()
            .copied()
            .fold(0.0f64, |acc, v| acc.max(v.abs()))
    }

    /// Sum of all elements.
    pub fn sum(&self) -> f64 {
        self.data.iter().sum()
    }
}

impl<const N: usize> Default for SimdBlock<N> {
    fn default() -> Self {
        Self::zeros()
    }
}

impl<const N: usize> std::fmt::Debug for SimdBlock<N> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SimdBlock")
            .field("len", &N)
            .field("data", &&self.data[..N.min(8)])
            .finish()
    }
}

impl<const N: usize> std::ops::Index<usize> for SimdBlock<N> {
    type Output = f64;
    fn index(&self, i: usize) -> &f64 {
        &self.data[i]
    }
}

impl<const N: usize> std::ops::IndexMut<usize> for SimdBlock<N> {
    fn index_mut(&mut self, i: usize) -> &mut f64 {
        &mut self.data[i]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zeros_and_splat() {
        let z = SimdBlock::<8>::zeros();
        assert!(z.data.iter().all(|&v| v == 0.0));

        let s = SimdBlock::<8>::splat(3.14);
        assert!(s.data.iter().all(|&v| v == 3.14));
    }

    #[test]
    fn from_slice_roundtrip() {
        let src: Vec<f64> = (0..16).map(|i| i as f64).collect();
        let b = SimdBlock::<16>::from_slice(&src);
        assert_eq!(b.as_slice(), &src[..]);
    }

    #[test]
    fn axpy_basic() {
        let mut a = SimdBlock::<7>::splat(1.0);
        let b = SimdBlock::<7>::splat(2.0);
        a.axpy(3.0, &b);
        assert!(a.data.iter().all(|&v| (v - 7.0).abs() < 1e-15));
    }

    #[test]
    fn scale_basic() {
        let mut a = SimdBlock::<5>::splat(4.0);
        a.scale(0.5);
        assert!(a.data.iter().all(|&v| (v - 2.0).abs() < 1e-15));
    }

    #[test]
    fn dot_basic() {
        let a = SimdBlock::<8>::splat(2.0);
        let b = SimdBlock::<8>::splat(3.0);
        assert!((a.dot(&b) - 48.0).abs() < 1e-12);
    }

    #[test]
    fn norm_inf_basic() {
        let mut a = SimdBlock::<6>::zeros();
        a.data[3] = -7.5;
        assert!((a.norm_inf() - 7.5).abs() < 1e-15);
    }

    #[test]
    fn sum_basic() {
        let src: Vec<f64> = (1..=10).map(|i| i as f64).collect();
        let b = SimdBlock::<10>::from_slice(&src);
        assert!((b.sum() - 55.0).abs() < 1e-12);
    }

    #[test]
    fn non_aligned_size() {
        let mut a = SimdBlock::<3>::splat(1.0);
        let b = SimdBlock::<3>::splat(2.0);
        a.axpy(1.0, &b);
        assert!(a.data.iter().all(|&v| (v - 3.0).abs() < 1e-15));
    }

    #[test]
    fn alignment_check() {
        let b = SimdBlock::<64>::zeros();
        let ptr = b.data.as_ptr() as usize;
        assert_eq!(ptr % 64, 0, "SimdBlock not 64-byte aligned");
    }
}
